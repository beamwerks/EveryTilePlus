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
   // ---- the stored tile bitmap ----------------------------------------
   // A GRID x GRID square of zoom-14 tiles centred on home, one bit each,
   // 1 = visited. Upstream stored 124x124 (a ~95km radius) and silently
   // dropped every tile beyond it; GRID now covers a long day out any way
   // you point.
   //
   // It is a ByteArray, not an Array of Number: a ByteArray is exactly one
   // byte per element, while an Array element carries VM overhead, which at
   // this size is the difference between fitting the 128KB data-field budget
   // comfortably and not fitting at all.
   //
   // Rows are byte aligned (GRID/8 bytes each) so a tile is addressed with
   // shifts alone: byte = ly*ROWB + (lx>>3), bit = 1 << (lx&7).
   const GRID  = 648;              // tiles per side (324 out = ~496km at 51N)
   const CTR   = 324;              // home sits at local index CTR
   const ROWB  = 81;               // bytes per row (GRID/8)
   const BROWS = 8;                // rows per storage band
   const BANDB = 648;              // bytes per band (ROWB*BROWS)
   const NBANDS = 81;              // GRID/BROWS

   // Upstream's 124x124 map put home at local index 61; the same tile now
   // lands at CTR, so carrying a stored map over is a shift by this much.
   const OLDG   = 124;
   const OLDSH  = 263;             // CTR - 61

   // The home defaults shipped in resources/properties/properties.xml. Used to
   // tell "the rider deliberately set this" from "nobody ever opened settings".
   const DEF_HLAT = 51.267202;
   const DEF_HLON = 7.150607;

   // bands[b] is null until something is ridden in those BROWS rows, and a
   // BANDB-byte ByteArray after that. Lazy, per-band allocation is what keeps
   // this inside a data field's heap: the whole grid as ONE 51KB ByteArray is a
   // contiguous block the device cannot hand out, and it dies at startup with
   // an Out Of Memory Error even though the total looks like it fits inside
   // 128KB (the simulator allocates it happily - hardware does not). This way
   // the largest single allocation is 648 bytes, a fresh install allocates no
   // bands at all, and RAM grows with the area actually explored.
   var bands;                      // Array<ByteArray or Null>, NBANDS entries
   hidden var bandDirty;           // per band: written since the last save?

   // Bounding box of everything visited, in local coords. Keeps the max-square
   // sweep proportional to the tiles actually ridden rather than to GRID^2
   // (420k cells), which would be far too slow to run on a tile change.
   // bbx0 < 0 means nothing has ever been recorded.
   var bbx0 = -1;
   var bby0 = -1;
   var bbx1 = -1;
   var bby1 = -1;

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
   var maxSq = 0;     // side of the largest solid block of visited tiles
   var maxSqDirty = false; // a new tile landed; the square needs recomputing
   var needsAnchor = false; // waiting for a first GPS fix to place home

   // One-line migration diagnostic, drawn on screen so an upgrade that goes
   // wrong on hardware can be read off the device instead of guessed at.
   var dbgOld = 0;    // size of the old stored map: 496, another size, or -1
   var dbgShift = 0;  // x shift used to re-centre it
   var dbgTiles = 0;  // tiles carried across


   function lat2lati(lat)
   {
      return (8192.0 - Math.ln(Math.tan(lat*0.0174532925199433) + (1.0 / Math.cos(lat*0.0174532925199433))) * 2607.59458761762).toNumber();
   }



   function lon2loni(lon)
   {
      return ((lon + 180.0) * 45.5111111111111).toNumber();
   }


   // ---- bit access ------------------------------------------------------

   // Mark local tile (lx,ly) visited, growing the bounding box and flagging
   // the band that has to be written back.
   hidden function setLocal(lx, ly)
   {
      var b = ly >> 3;
      var ba = bands[b];
      if (ba == null) { ba = new [BANDB]b; bands[b] = ba; }
      ba[(ly & 7)*ROWB + (lx>>3)] |= (1 << (lx&7));
      bandDirty[b] = true;
      if (bbx0 < 0)
      {
         bbx0 = lx;  bbx1 = lx;  bby0 = ly;  bby1 = ly;
      }
      else
      {
         if (lx < bbx0) { bbx0 = lx; }
         if (lx > bbx1) { bbx1 = lx; }
         if (ly < bby0) { bby0 = ly; }
         if (ly > bby1) { bby1 = ly; }
      }
   }

   hidden function getLocal(lx, ly)
   {
      var ba = bands[ly >> 3];
      if (ba == null) { return 0; }         // never ridden: no band allocated
      return ((ba[(ly & 7)*ROWB + (lx>>3)] & (1 << (lx&7))) != 0) ? 1 : 0;
   }


   function bigmap2lmap(xi,yi)
    {
       var x;
       var y;
       for(x=xi-hloni+CTR-2; x<xi-hloni+CTR+3; x++)
       {
          for(y=yi-hlati+CTR-2; y<yi-hlati+CTR+3; y++)
          {
             if ( (x < 0) || (x>GRID-1) || (y<0) || (y>GRID-1) )
             {
                //too far out for permanent storage
                ltiles[5*(y-yi+hlati-CTR+2) + x-xi+hloni-CTR+2] = 0;
             }else
             {
                ltiles[5*(y-yi+hlati-CTR+2) + x-xi+hloni-CTR+2] = getLocal(x,y);
             }
          }
       }
    }



    function setBigMap(xi,yi)
    {
       xi += (CTR-hloni);
       yi += (CTR-hlati);
       if ( (xi>=0) && (xi<GRID) && (yi>=0) && (yi<GRID) )
       {
          setLocal(xi, yi);
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
         // only a brand new tile can grow the max square. The sweep itself is
         // deferred (see computeMaxSquare) so it never shares a tick with the
         // storage save the caller does right after this.
         maxSqDirty = true;
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

   // Column c (0..123) of one decoded seed row. The seed packs 124 columns as
   // 4 groups of 31: within a group, chars 5w..5w+4 carry 6 bits each (columns
   // 31w..31w+29) and the row's final char supplies the 31st column of each
   // group as one of its low 4 bits.
   hidden function seedBit(vec, c)
   {
      var w = c / 31;
      var r = c % 31;
      if (r == 30) { return (b64v(vec[20]) >> w) & 1; }
      return (b64v(vec[5*w + r/6]) >> (r % 6)) & 1;
   }


   // ---- persistence -----------------------------------------------------
   // The bitmap is stored as NBANDS strips of BROWS rows. A tile change dirties
   // exactly one band, so a save writes 648 bytes rather than the whole 51KB,
   // and bands that were never ridden are never written at all.

   hidden function blankMap()
   {
      bands = new [NBANDS];
      bandDirty = new [NBANDS];
      var i;
      for (i = 0; i < NBANDS; i++) { bands[i] = null; bandDirty[i] = false; }
      bbx0 = -1;  bby0 = -1;  bbx1 = -1;  bby1 = -1;
   }

   hidden function loadBands()
   {
      blankMap();
      var b;
      var i;
      var found = false;
      for (b = 0; b < NBANDS; b++)
      {
         var chunk = null;
         try { chunk = Storage.getValue("bm" + b); } catch (ex) { chunk = null; }
         if (chunk == null) { continue; }
         if (chunk.size() != BANDB) { continue; }   // corrupt: treat as empty
         found = true;
         bands[b] = chunk;      // adopt it as-is; no copy, no extra allocation
      }
      if (found)
      {
         var bb = Storage.getValue("bmbb");
         if ((bb != null) && (bb.size() == 4))
         {
            bbx0 = bb[0];  bby0 = bb[1];  bbx1 = bb[2];  bby1 = bb[3];
         }
         else
         {
            rescanBBox();      // lost or never written: rebuild it
         }
      }
      return found;
   }

   // Rebuild the visited bounding box from the bitmap. Only needed when the
   // saved box is missing, so a full sweep is acceptable here.
   hidden function rescanBBox()
   {
      bbx0 = -1;  bby0 = -1;  bbx1 = -1;  bby1 = -1;
      var b;
      var r;
      var y;
      var xb;
      var k;
      for (b = 0; b < NBANDS; b++)
      {
         var ba = bands[b];
         if (ba == null) { continue; }      // whole strip never ridden
         for (r = 0; r < BROWS; r++)
         {
         y = (b << 3) + r;
         var off = r * ROWB;
         for (xb = 0; xb < ROWB; xb++)
         {
            var v = ba[off+xb];
            if (v == 0) { continue; }
            for (k = 0; k < 8; k++)
            {
               if ((v & (1<<k)) != 0)
               {
                  var lx = (xb<<3) + k;
                  if (bbx0 < 0)
                  {
                     bbx0 = lx;  bbx1 = lx;  bby0 = y;  bby1 = y;
                  }
                  else
                  {
                     if (lx < bbx0) { bbx0 = lx; }
                     if (lx > bbx1) { bbx1 = lx; }
                     if (y  < bby0) { bby0 = y;  }
                     if (y  > bby1) { bby1 = y;  }
                  }
               }
            }
         }
         }
      }
   }

   // Carry a map saved by an older version (a 496 int Array holding 124x124
   // centred on local index 61) into the new grid. A pure re-index by OLDSH,
   // so it is only valid while home is unchanged - the caller checks that.
   //
   // The old key is deliberately LEFT IN PLACE rather than deleted. It costs
   // about 2KB and nothing ever writes to it again, but it means a rider who
   // goes back to an older build still has their map: migration is a copy, not
   // a move. Worth 2KB to make the one upgrade that cannot be undone undoable.
   hidden function migrateOldMap()
   {
      // Reading the object store can throw rather than return null, so an
      // unreadable old map is not worth taking the app down for: note it and
      // carry on with an empty one, which the rider can re-seed.
      //
      // NOTE this does not save a genuinely corrupt store. A store whose .IDX
      // does not match its .DAT raises a System Error, and Monkey C catch only
      // takes Lang.Exception - the fault comes straight back out of this try
      // and the field still dies. Verified on hardware: the crash was logged
      // at the getValue line INSIDE this block. Only a store the device built
      // itself can be relied on here.
      var old = null;
      try
      {
         old = Storage.getValue("bigMap");
      }
      catch (ex)
      {
         dbgOld = -2;        // store unreadable
         return false;
      }
      if (old == null) { dbgOld = -1; return false; }
      if (old.size() != 496) { dbgOld = old.size(); return false; }
      dbgOld = 496;

      // The old map was stored relative to whatever home that build was using.
      // If that home is still recorded, re-centre against IT rather than
      // assuming it matches the current one. A home that has since moved then
      // shifts the tiles to where they actually belong, instead of the map
      // being read as stale and thrown away - which is what destroyed it on
      // the first 1.1.0 install over a store build.
      var shx = OLDSH;
      var shy = OLDSH;
      var ohlat = Storage.getValue("hlat");
      var ohlon = Storage.getValue("hlon");
      if ((ohlat != null) && (ohlon != null))
      {
         shx = OLDSH + (lon2loni(ohlon) - hloni);
         shy = OLDSH + (lat2lati(ohlat) - hlati);
      }
      dbgShift = shx;

      var x;
      var y;
      var n = 0;
      for (y = 0; y < OLDG; y++)
      {
         var ny = y + shy;
         if ((ny < 0) || (ny >= GRID)) { continue; }
         for (x = 0; x < OLDG; x++)
         {
            var nx = x + shx;
            if ((nx < 0) || (nx >= GRID)) { continue; }
            if ((old[y*4 + x/31] & (1 << (x % 31))) != 0)
            {
               setLocal(nx, ny);
               n++;
            }
         }
      }
      dbgTiles = n;
      save();       // write the bands out; the old key stays as a fallback
      return true;
   }

   function save()
   {
      var b;
      var i;
      for (b = 0; b < NBANDS; b++)
      {
         if (!bandDirty[b]) { continue; }
         Storage.setValue("bm" + b, bands[b]);
         bandDirty[b] = false;
      }
      Storage.setValue("bmbb", [bbx0, bby0, bbx1, bby1]);
      Storage.setValue("newTiles",newTiles);
      Storage.setValue("newTilesR",newTilesR);
   }

   // Drop every stored band. Used when home moves or a new seed replaces the
   // map, where the old bits would now name different tiles.
   hidden function wipeStored()
   {
      var b;
      for (b = 0; b < NBANDS; b++) { Storage.deleteValue("bm" + b); }
      Storage.deleteValue("bmbb");
   }


   // Has the rider actually chosen a home, or is this still the shipped
   // default? Floats, so compare with a tolerance rather than for equality.
   function homeWasSet()
   {
      return (((hlat - DEF_HLAT).abs() > 0.000001) ||
              ((hlon - DEF_HLON).abs() > 0.000001));
   }

   // True while nothing has ever been recorded in the stored bitmap.
   function mapIsEmpty()
   {
      return (bbx0 < 0);
   }

   // Pin the stored window on the rider's first GPS fix. Called once, from
   // compute(), when nobody set a home and there is nothing to import -
   // otherwise such a rider keeps the shipped default (Germany) and, riding
   // anywhere else, silently records nothing at all, for ever.
   //
   // The anchor is kept in storage rather than written back to the home
   // property on purpose: the property is owned by the phone, and a later
   // settings sync pushing the old default back would read as "the rider
   // changed home" and wipe the map. Storage is device-side and cannot be
   // overwritten that way, and initialize() ignores the property entirely
   // while it still holds the default, so a re-sync is a no-op.
   function anchorHome(lat, lon)
   {
      hlat = lat;
      hlon = lon;
      hlati = lat2lati(hlat);
      hloni = lon2loni(hlon);
      clat = hlat;
      clon = hlon;
      lati = hlati;
      loni = 16385;        // force the next setMap() to record the current tile
      needsAnchor = false;

      Storage.setValue("autoHlat", hlat);
      Storage.setValue("autoHlon", hlon);
      Storage.setValue("hlat", hlat);
      Storage.setValue("hlon", hlon);
   }

   function initialize()
   {
       var i=0;
       var str;
       var vec;
       hlat = Properties.getValue("homeLatitude");
       hlon = Properties.getValue("homeLongitude");
       str = Properties.getValue("bmapstr");
       if (hlat == null) { hlat = DEF_HLAT; }
       if (hlon == null) { hlon = DEF_HLON; }
       // needed by migrateOldMap() below; recomputed at the end, and again by
       // anchorHome() if the first GPS fix ends up placing home.
       hlati = lat2lati(hlat);
       hloni = lon2loni(hlon);

       var hasSeed = (str != null) && (str.length() == 2604);

       // Load what is already stored, so "has this rider got tiles?" can be
       // answered before deciding where home goes.
       var migrated = false;
       if (!loadBands())
       {
          migrated = migrateOldMap();   // nothing banded: carry an older map over
       }

       // A map carried over from an older version was built by that version
       // against the home it was already running with, so by definition home
       // has not moved and any seed has already been applied. Older builds did
       // not always record hlat/hlon though, and the checks below read a
       // missing value as "home moved" and wipe the map that was just
       // recovered - which is exactly what happened on the first 1.1.0 install
       // over a store build. Stamp only the keys that are MISSING: a home that
       // genuinely changed still has both values stored, still compares
       // unequal, and is still honoured with a wipe.
       if (migrated)
       {
          // The migrated bits are now expressed against the CURRENT home, so
          // nothing downstream should treat this as a home change and wipe
          // them. A genuinely moved home was already handled by re-centring.
          Storage.setValue("hlat", hlat);
          Storage.setValue("hlon", hlon);
          if (hasSeed) { Storage.setValue("bmapApplied", str); }
       }

       // No import, and the home setting never touched: hold home until the
       // first GPS fix and pin it there (see anchorHome). Riders who already
       // have tiles recorded against the default home are left alone - they
       // really do ride near it - as are riders who set a home themselves.
       if (!hasSeed && !homeWasSet())
       {
          var alat = Storage.getValue("autoHlat");
          var alon = Storage.getValue("autoHlon");
          if ((alat != null) && (alon != null))
          {
             hlat = alat;   // anchored on an earlier ride; keep that home
             hlon = alon;
          }
          else if (mapIsEmpty())
          {
             needsAnchor = true;
          }
       }

       // Re-apply the seed string ONLY when it actually changes (or home moves),
       // so re-syncing the same value from Garmin Express is a no-op and never
       // wipes ride progress. The last-applied string is remembered in storage,
       // and the bmapstr property is left untouched (customers never clear it).
       var applied = Storage.getValue("bmapApplied");
       var homeChanged = (hlat != Storage.getValue("hlat")) || (hlon != Storage.getValue("hlon"));
       var seedChanged = hasSeed && ((applied == null) || !str.equals(applied));

       if (hasSeed && (seedChanged || homeChanged))
       {
          // A new or changed seed string -> decode it, replacing the map. The
          // seed is 124x124 around home, so it lands in the middle of the much
          // larger grid, offset by OLDSH on both axes.
          wipeStored();
          blankMap();
          for (i=0; i<124; i++)
          {
                vec = str.substring(i*21,i*21+21).toUtf8Array();
                var c;
                for (c = 0; c < 124; c++)
                {
                   if (seedBit(vec, c) != 0) { setLocal(c + OLDSH, i + OLDSH); }
                }
          }
          save();
          Storage.setValue("bmapApplied", str);
          Storage.setValue("hlat", hlat);
          Storage.setValue("hlon", hlon);
       }
       else if (homeChanged)
       {
          // Home moved and there is no seed -> the old bits name other tiles.
          wipeStored();
          blankMap();
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
       computeMaxSquare();
   }

   // 1 if the global tile (gx,gy) has ever been visited, else 0 (for display).
   function tileVisited(gx, gy)
   {
      var lx = gx - hloni + CTR;
      var ly = gy - hlati + CTR;
      if ((lx < 0) || (lx > GRID-1) || (ly < 0) || (ly > GRID-1))
      {
         return 0;
      }
      return getLocal(lx, ly);
   }

   // Is the global tile (gx,gy) never-visited? Tiles outside the saved area
   // are unknown, so we treat them as new too.
   function isUnexplored(gx, gy)
   {
      var lx = gx - hloni + CTR;
      var ly = gy - hlati + CTR;
      if ((lx < 0) || (lx > GRID-1) || (ly < 0) || (ly > GRID-1))
      {
         return true;
      }
      return (getLocal(lx, ly) == 0);
   }


   // "Max square": the side of the largest solid square of visited tiles (the
   // VeloViewer metric) - ride every tile of a 5x5 block and it reads 5.
   // Classic maximal-square DP: each cell holds the side of the biggest solid
   // square whose bottom-right corner it is, which is 1 + the smallest of its
   // north, west and north-west neighbours. Only two rows are kept, and the
   // sweep covers just the visited bounding box rather than all GRID^2 cells,
   // so it costs what the rider has actually ridden. Run at startup and then
   // only when maxSqDirty says a never-before-visited tile has been added.
   function computeMaxSquare()
   {
      maxSqDirty = false;
      if (bbx0 < 0) { maxSq = 0; return; }

      var w = bbx1 - bbx0 + 1;
      var prev = new[w+1];
      var cur  = new[w+1];
      var i;
      for (i = 0; i <= w; i++) { prev[i] = 0; cur[i] = 0; }

      var best = 0;
      var x;
      var y;
      for (y = bby0; y <= bby1; y++)
      {
         var ba = bands[y >> 3];
         var off = (y & 7) * ROWB;
         var c = 1;
         for (x = bbx0; x <= bbx1; x++)
         {
            if ((ba != null) && ((ba[off + (x>>3)] & (1 << (x&7))) != 0))
            {
               var m = prev[c];                            // north
               if (cur[c-1]  < m) { m = cur[c-1];  }       // west
               if (prev[c-1] < m) { m = prev[c-1]; }       // north-west
               m++;
               cur[c] = m;
               if (m > best) { best = m; }
            }
            else
            {
               cur[c] = 0;
            }
            c++;
         }
         var t = prev;  prev = cur;  cur = t;
         cur[0] = 0;
      }

      maxSq = best;
   }


   hidden var nntBest = null;
   hidden var nntBestD = 0.0;

   // Consider one tile for "nearest new tile", scoring it by the distance from
   // (fx,fy) to its NEAREST POINT so the tile you are about to ride into wins
   // over equidistant neighbours.
   hidden function nntCheck(x, y, fx, fy)
   {
      if (!isUnexplored(x, y)) { return; }
      var ddx = 0.0;
      if (fx < x)          { ddx = x - fx; }
      else if (fx > x + 1) { ddx = fx - (x + 1); }
      var ddy = 0.0;
      if (fy < y)          { ddy = y - fy; }
      else if (fy > y + 1) { ddy = fy - (y + 1); }
      var dd = ddx * ddx + ddy * ddy;
      if ((nntBest == null) || (dd < nntBestD))
      {
         nntBest = [x, y];
         nntBestD = dd;
      }
   }

   // Nearest never-visited ("new") tile to the current position (fx,fy in
   // fractional tile coords), as global tile coords [x,y]; null if none found.
   // Expanding-ring search bounds the work; two extra rings are scanned past
   // the first hit so a closer tile cannot be missed. Only the ring's PERIMETER
   // is walked - rescanning the whole square each ring is O(r^3) overall, which
   // the old 124 limit just about tolerated and this grid would not.
   function nearestNewTile(fx, fy)
   {
      var cx = loni;
      var cy = lati;
      nntBest = null;
      nntBestD = 0.0;
      var stopR = -1;
      var r;
      var x;
      var y;
      for (r = 1; r <= GRID; r++)
      {
         for (x = cx - r; x <= cx + r; x++)
         {
            nntCheck(x, cy - r, fx, fy);
            nntCheck(x, cy + r, fx, fy);
         }
         for (y = cy - r + 1; y <= cy + r - 1; y++)
         {
            nntCheck(cx - r, y, fx, fy);
            nntCheck(cx + r, y, fx, fy);
         }
         if (nntBest != null)
         {
            if (stopR < 0) { stopR = r + 2; }
            if (r >= stopR) { break; }
         }
      }
      return nntBest;
   }

}
