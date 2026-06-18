//! Copyright (C) 2018 Tomasz Korzec <tom@shmo.de>
//!
//! This program is free software: you can redistribute it and/or modify it
//! under the terms of the GNU General Public License as published by the Free
//! Software Foundation, either version 3 of the License, or (at your option)
//! any later version.
//!
//! This program is distributed in the hope that it will be useful, but WITHOUT
//! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//! FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//! more details.
//!
//! You should have received a copy of the GNU General Public Lice

using Toybox.Application.Storage;
using Toybox.Application.Properties;

class map{
   var bigMap; // compressed map of tiles. 124 rows x 124 columns.
               // Each value stores 31 bits, 1=visited, 0=unvisited tile
               // only positive integers are used
   var ltiles = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];

   var hlat;     // home latitude
   var hlon;     // home longitude
   var hlati=0;  // home tile y
   var hloni=0;  // home tile x
   var loni;     // current tile x
   var lati;     // current tile y
   var clon;     // current position x
   var clat;     // current position y
   var newTiles = 0;  // tiles visited for the first time
   var newTilesR = 0; // tiles visited for the first time this ride


   function lat2lati(lat)
   {
      return (8192.0 - Math.ln(Math.tan(lat*0.0174532925199433) + (1.0 / Math.cos(lat*0.0174532925199433))) * 2607.59458761762).toNumber();
   }



   function lon2loni(lon)
   {
      return ((lon + 180.0) * 45.5111111111111).toNumber();
   }

   function bigmap2lmap(xi,yi)
    {
       var x;
       var y;
       for(x=xi-hloni+59; x<xi-hloni+64; x++)
       {
          for(y=yi-hlati+59; y<yi-hlati+64; y++)
          {
             if ( (x < 0) || (x>123) || (y<0) || (y>123) )
             {
                //too far out for permanent storage
                ltiles[5*(y-yi+hlati-59) + x-xi+hloni-59] = 0;
             }else
             {
                ltiles[5*(y-yi+hlati-59) + x-xi+hloni-59] = (bigMap[y*4+x/31] & (1<<(x%31))) >> (x%31);
             }
          }
       }
    }



    function setBigMap(xi,yi)
    {
       xi += (61-hloni);
       yi += (61-hlati);
       if ( (xi>=0) && (xi<124) && (yi>=0) && (yi<124) )
       {
          bigMap[yi*4+xi/31] |= (1<<(xi%31));
       }
    }


   function setMap(lon,lat)
   {
      var xi = lon2loni(lon);
      var yi = lat2lati(lat);
      clon = lon;
      clat = lat;

      if((xi!=loni) || (yi!=lati))
      {
         bigmap2lmap(xi,yi);
         setBigMap(xi,yi);
         loni = xi;
         lati = yi;
         return true;
      }else
      {
         return false;
      }
   }

   function setTiles(cpath,clp)
   {
      var i;
      var lx;
      var ly;
      for (i=0;i<clp;i++)
      {
         lx = lon2loni(cpath[2*i])   - loni + 2;
         ly = lat2lati(cpath[2*i+1]) - lati + 2;
         if( (lx>=0) && (lx<5) && (ly>=0) && (ly<5))
         {
            ltiles[lx+ly*5]=2;
         }
      }

      if (ltiles[12]==1)
      {
         newTilesR++;
      }
      if (ltiles[12]==0)
      {
         newTilesR++;
         newTiles++;
      }
      ltiles[12]=2;
   }


   // base64url character byte -> 6-bit value (A-Z=0..25, a-z=26..51,
   // 0-9=52..61, '-'=62, '_'=63)
   function b64v(c)
   {
      if ((c >= 65) && (c <= 90))  { return c - 65; }
      if ((c >= 97) && (c <= 122)) { return c - 71; }
      if ((c >= 48) && (c <= 57))  { return c + 4; }
      if (c == 45) { return 62; }
      return 63;   // '_' (95)
   }

   function initialize()
   {
       var i=0;
       var str;
       var vec;
       hlat = Properties.getValue("homeLatitude");
       hlon = Properties.getValue("homeLongitude");
       bigMap = Storage.getValue("bigMap");
       str = Properties.getValue("bmapstr");

       // Re-apply the seed string ONLY when it actually changes (or home moves),
       // so re-syncing the same value from Garmin Express is a no-op and never
       // wipes ride progress. The last-applied string is remembered in storage,
       // and the bmapstr property is left untouched (customers never clear it).
       var applied = Storage.getValue("bmapApplied");
       var homeChanged = (hlat != Storage.getValue("hlat")) || (hlon != Storage.getValue("hlon"));
       var hasSeed = (str != null) && (str.length() == 2604);
       var seedChanged = hasSeed && ((applied == null) || !str.equals(applied));

       if (hasSeed && (seedChanged || homeChanged))
       {
          // a new or changed seed string -> decode it, replacing the map
          bigMap = new[496];
          for (i=0; i<124; i++)
          {
                vec = str.substring(i*21,i*21+21).toUtf8Array();
                /*
                bigMap[i*4]   = ((vec[0]-48) & 0x3f)
                               +((vec[1]-48) & 0x3f)<<6
                               +((vec[2]-48) & 0x3f)<<12
                               +((vec[3]-48) & 0x3f)<<18
                               +((vec[4]-48) & 0x3f)<<24
                               +((vec[20]-48) & 0x01)<<30;
                bigMap[i*4+1] = ((vec[5]-48) & 0x3f)
                               +((vec[6]-48) & 0x3f)<<6
                               +((vec[7]-48) & 0x3f)<<12
                               +((vec[8]-48) & 0x3f)<<18
                               +((vec[9]-48) & 0x3f)<<24
                               +((vec[20]-48) & 0x02)<<29;
                bigMap[i*4+2] = ((vec[10]-48) & 0x3f)
                               +((vec[11]-48) & 0x3f)<<6
                               +((vec[12]-48) & 0x3f)<<12
                               +((vec[13]-48) & 0x3f)<<18
                               +((vec[14]-48) & 0x3f)<<24
                               +((vec[20]-48) & 0x04)<<28;
                bigMap[i*4+3] = ((vec[15]-48) & 0x3f)
                               +((vec[16]-48) & 0x3f)<<6
                               +((vec[17]-48) & 0x3f)<<12
                               +((vec[18]-48) & 0x3f)<<18
                               +((vec[19]-48) & 0x3f)<<24
                               +((vec[20]-48) & 0x08)<<27;
               */
               // decode 21 base64url chars -> 4 x 31-bit words (columns 0..123)
               var b = i*4;
               var ov = b64v(vec[20]);
               bigMap[b]   = b64v(vec[0])
                           | (b64v(vec[1])<<6)
                           | (b64v(vec[2])<<12)
                           | (b64v(vec[3])<<18)
                           | (b64v(vec[4])<<24)
                           | ((ov & 0x01)<<30);
               bigMap[b+1] = b64v(vec[5])
                           | (b64v(vec[6])<<6)
                           | (b64v(vec[7])<<12)
                           | (b64v(vec[8])<<18)
                           | (b64v(vec[9])<<24)
                           | ((ov & 0x02)<<29);
               bigMap[b+2] = b64v(vec[10])
                           | (b64v(vec[11])<<6)
                           | (b64v(vec[12])<<12)
                           | (b64v(vec[13])<<18)
                           | (b64v(vec[14])<<24)
                           | ((ov & 0x04)<<28);
               bigMap[b+3] = b64v(vec[15])
                           | (b64v(vec[16])<<6)
                           | (b64v(vec[17])<<12)
                           | (b64v(vec[18])<<18)
                           | (b64v(vec[19])<<24)
                           | ((ov & 0x08)<<27);
          }
          Storage.setValue("bmapApplied", str);
          Storage.setValue("bigMap", bigMap);
          Storage.setValue("hlat", hlat);
          Storage.setValue("hlon", hlon);
       }
       else if ((bigMap == null) || homeChanged)
       {
          // first run (or home moved) with no seed -> start blank
          bigMap = new[496];
          for (i=0; i<496; i++)
          {
             bigMap[i] = 0;
          }
          Storage.setValue("bigMap", bigMap);
          Storage.setValue("hlat", hlat);
          Storage.setValue("hlon", hlon);
       }

       hlati = lat2lati(hlat);
       hloni = lon2loni(hlon);
       clat = hlat;
       clon = hlon;
       loni=hloni;
       lati=hlati;
       newTiles=0;
       newTilesR=0;
       bigmap2lmap(hloni,hlati);
   }

   // 1 if the global tile (gx,gy) has ever been visited, else 0 (for display).
   function tileVisited(gx, gy)
   {
      var lx = gx - hloni + 61;
      var ly = gy - hlati + 61;
      if ((lx < 0) || (lx > 123) || (ly < 0) || (ly > 123))
      {
         return 0;
      }
      return ((bigMap[ly*4 + lx/31] & (1 << (lx % 31))) != 0) ? 1 : 0;
   }

   // Is the global tile (gx,gy) never-visited? Tiles outside the saved 124x124
   // area are unknown, so we treat them as new too.
   function isUnexplored(gx, gy)
   {
      var lx = gx - hloni + 61;
      var ly = gy - hlati + 61;
      if ((lx < 0) || (lx > 123) || (ly < 0) || (ly > 123))
      {
         return true;
      }
      return ((bigMap[ly*4 + lx/31] & (1 << (lx % 31))) == 0);
   }

   // Nearest never-visited ("new") tile to the current position (fx,fy in
   // fractional tile coords), as global tile coords [x,y]; null if none found.
   // Selection uses the distance from (fx,fy) to the *nearest point* of each
   // tile, so the tile you are about to ride into wins over equidistant
   // neighbours. Expanding-ring search bounds the work; two extra rings are
   // scanned past the first hit so a closer tile can't be missed.
   function nearestNewTile(fx, fy)
   {
      var cx = loni;
      var cy = lati;
      var best = null;
      var bestD = 0.0;
      var stopR = -1;
      var r;
      var x;
      var y;
      for (r = 1; r <= 124; r++)
      {
         for (x = cx - r; x <= cx + r; x++)
         {
            for (y = cy - r; y <= cy + r; y++)
            {
               // ring only - skip the interior already scanned at smaller r
               if ((x > cx - r) && (x < cx + r) && (y > cy - r) && (y < cy + r))
               {
                  continue;
               }
               if (isUnexplored(x, y))
               {
                  var ddx = 0.0;
                  if (fx < x)     { ddx = x - fx; }
                  else if (fx > x + 1) { ddx = fx - (x + 1); }
                  var ddy = 0.0;
                  if (fy < y)     { ddy = y - fy; }
                  else if (fy > y + 1) { ddy = fy - (y + 1); }
                  var dd = ddx * ddx + ddy * ddy;
                  if ((best == null) || (dd < bestD))
                  {
                     best = [x, y];
                     bestD = dd;
                  }
               }
            }
         }
         if (best != null)
         {
            if (stopR < 0) { stopR = r + 2; }
            if (r >= stopR) { break; }
         }
      }
      return best;
   }

   function save()
   {
      Storage.setValue("bigMap",bigMap);
      Storage.setValue("newTiles",newTiles);
      Storage.setValue("newTilesR",newTilesR);
   }

}