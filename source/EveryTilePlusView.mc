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

using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Math as Math;
using Toybox.Activity as Act;
using Toybox.Application.Storage;
using Toybox.System as Sys;

class EveryTilePlusView extends Ui.DataField {
    // Colourblind-safe tile palette (orange vs blue is distinguishable by all
    // common types of colour blindness, and by luminance). The two "done"
    // states differ by brightness so they read even in greyscale.
    const COL_UNVIS = 0xFF7E00; // never visited (was red)
    const COL_VIS   = 0x0061C2; // visited on a previous ride (was dark green)
    const COL_RIDE  = 0x36C4FF; // touched this ride (was bright green)

    hidden var tileW = 50;
    hidden var tileH = 50;
    hidden var dts = 50;    // current display tile size (varies with auto-zoom)
    hidden var dcl = 0;     // screen x of current tile's left edge
    hidden var dct = 0;     // screen y of current tile's top edge
    hidden var navNt = null; // nearest new tile [x,y] global, or null
    hidden var navAng = 0.0; // heading-relative bearing to it (radians)
    hidden var navDist = ""; // formatted distance to it
    hidden var initialized = false;

    hidden var pt;          // fine path
    hidden var cpt;         // coarse path

    hidden var tx = new[6]; // coordinates of tiles on the screen
    hidden var ty = new[6];
    hidden var dx = 0;      // screen size
    hidden var dy = 0;
    hidden var heading = 0.0;
    hidden var dispHdg = 0.0; // smoothed map orientation (radians, track-up)
    hidden var tgtHdg = 0.0;  // orientation target (last heading while moving)
    hidden var rfx = 0.0;     // rider tile-x pivot for rotation
    hidden var rfy = 0.0;     // rider tile-y pivot
    hidden var pcx = 0;       // screen centre (rider) x
    hidden var pcy = 0;       // screen centre (rider) y
    hidden var ch = 1.0;      // cos(dispHdg)
    hidden var sh = 0.0;      // sin(dispHdg)
    hidden var mp;          // main map object
    hidden var landsc=false;
    hidden var mx;
    hidden var my;
    hidden var singleDF = true;


    // fractional tile coords -> screen pixel, rotated track-up about the rider.
    // (rfx,rfy) is the rider's tile position (the pivot), (pcx,pcy) the screen
    // centre, and (ch,sh)=cos/sin(dispHdg) give a rotation by -dispHdg so the
    // direction of travel points up.
    function fpx(fx, fy)
    {
       var ox = (fx - rfx) * dts;
       var oy = (fy - rfy) * dts;
       return [ Math.round(pcx + ox*ch + oy*sh).toNumber(),
                Math.round(pcy - ox*sh + oy*ch).toNumber() ];
    }

    // lat/lon (degrees) -> screen pixel (track-up)
    function deg2px(dgr)
    {
       var fx = (dgr[1] + 180.0) * 45.5111111111111;
       var rad = dgr[0] * 0.0174532925199433;
       var fy = 8192.0 - Math.ln(Math.tan(rad) + 1.0 / Math.cos(rad)) * 2607.59458761762;
       return fpx(fx, fy);
    }

    // fill one global tile (tile coords gx,gy) as a rotated quad
    function fillTile(dc, gx, gy, col)
    {
       var p0 = fpx(gx,   gy);
       var p1 = fpx(gx+1, gy);
       var p2 = fpx(gx+1, gy+1);
       var p3 = fpx(gx,   gy+1);
       dc.setColor(col, col);
       dc.fillPolygon([p0, p1, p2, p3]);
    }

    // Choose the grid size (odd, 5..13) so the nearest unexplored tile is just
    // on screen with a tile of margin; shrinks back to 5x5 as you approach it.
    // Uses straight-line (Euclidean) distance, not Chebyshev, because the map is
    // track-up: a target off to the side must stay inside the inscribed circle
    // (radius = half the SHORTER screen edge), so a diagonal target needs the
    // same room as one straight ahead.
    function chooseZoom()
    {
       if (navNt == null) { return 5; }
       var ax = (navNt[0] - mp.loni).toFloat();
       var ay = (navNt[1] - mp.lati).toFloat();
       var d = Math.sqrt(ax*ax + ay*ay);   // Euclidean distance, in tiles
       var nv = 2 * (Math.ceil(d).toNumber() + 1) + 1;
       if (nv < 5)  { nv = 5; }
       if (nv > 13) { nv = 13; }
       return nv;
    }

    function pxdist(dgr1,dgr2)
    {
       if (  (   ((dgr1[1]-dgr2[1]) * 45.5111111111111 * tileW ).abs().toNumber()>1 ) ||
             (   ( (- Math.ln(Math.tan(dgr1[0]*0.0174532925199433) + (1.0 / Math.cos(dgr1[0]*0.0174532925199433)))
                    + Math.ln(Math.tan(dgr2[0]*0.0174532925199433) + (1.0 / Math.cos(dgr2[0]*0.0174532925199433))) ) * 0.318309886183791 *8192*tileH
                 ).abs().toNumber()>1))
       {
          return true;
       }else
       {
          return false;
       }
    }


    function initialize()
    {
       DataField.initialize();
       mp = new map();
       pt = new path(50,mp.hlon,mp.hlat);
       cpt= new path(200,mp.hlon,mp.hlat);

       initialized=false;

       var inf = Act.getActivityInfo();
       if( (inf!=null) && (inf.elapsedTime > 10000) )
       {
          // attempt to continue activity
          mp.newTiles=Storage.getValue("newTiles");
          mp.newTilesR=Storage.getValue("newTilesR");
          if( cpt.load() && (mp.newTiles!=null) && (mp.newTilesR!=null) )
          {
             pt.set(0,cpt.getDeg(null));
             mp.setMap(pt.p[0],pt.p[1]);
             initialized = true;
          }else
          {
             mp.newTiles = 0;
             mp.newTilesR = 0;
          }
       }
    }

    function onTimerReset()
    {
       initialized=false;
    }


    (:ed520)
    function onLayout(dc)
    {
       // hard coded for devices with 200x265
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if (dx != 200 || dy != 265)
       {
          singleDF = false;
       }else
       {
          singleDF = true;
       }
       tx=[ 0, 25,  75, 125, 175, 201];
       ty=[40, 65, 115, 165, 215, 266];
       tileW=50;
       tileH=50;

       return;
    }

    (:ed530)
    function onLayout(dc)
    {
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if(dx>dy)
       {
          // hard coded for devices with 322x246
          if (dx != 322 || dy != 246)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          tx=[ 72, 122,  172, 222, 272, 323];
          ty=[0, 48, 98, 148, 198, 247];
          tileW=50;
          tileH=50;
          landsc = true;
       }else
       {
          // hard coded for devices with 246x322
          if (dx != 246 || dy != 322)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          ptGeom(dc, 50);
          landsc = false;
       }
       return;
    }

    // Portrait grid + header geometry. The header is sized to fit two stat rows
    // plus the nav row (font-derived) so it stays snug at every resolution; the
    // 5x5 tile grid fills the rest. tw = full tile pixel width for the device.
    function ptGeom(dc, tw)
    {
       dx = dc.getWidth();
       dy = dc.getHeight();
       mx = dx >> 1;
       my = dy >> 1;
       var fhM = dc.getFontHeight(Gfx.FONT_MEDIUM);
       var fhS = dc.getFontHeight(Gfx.FONT_SMALL);
       var hdr = 2 + 2 * fhM + fhS + 4;     // two stat rows + the nav row, packed
       var edge = (dx - 3 * tw) / 2;
       tileW = tw;
       tileH = (dy - hdr) / 5;
       tx = [0, edge, edge + tw, edge + 2 * tw, edge + 3 * tw, dx];
       ty = [hdr, hdr + tileH, hdr + 2 * tileH, hdr + 3 * tileH, hdr + 4 * tileH, dy];
    }


    (:ed1000)
    function onLayout(dc)
    {
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if(dx>dy)
       {
          // hard coded for devices with 400x240
          if (dx != 400 || dy != 240)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          tx=[ 100, 160,  220, 280, 340, 401];
          ty=[0, 30, 90, 150, 210, 241];
          tileW=60;
          tileH=60;
          landsc = true;
       }else
       {
          // hard coded for devices with 240x400
          if (dx != 240 || dy != 400)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          ptGeom(dc, 60);
          landsc = false;
       }
       return;
    }

    (:ed1030)
    function onLayout(dc)
    {
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if(dx>dy)
       {
          // hard coded for devices with 470x282
          if (dx != 470 || dy != 282)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          tx=[ 110, 182,  254, 326, 398, 471];
          ty=[ 0, 33,  105, 177, 249, 283];
          tileW=72;
          tileH=72;
       }else
       {
          // hard coded for devices with 282x470
          if (dx != 282 || dy != 470)
          {
             singleDF = false;
          }else
          {
             singleDF = true;
          }
          ptGeom(dc, 72);
          landsc = false;
       }

       return;
    }

    (:ed1050)
    function onLayout(dc)
    {
       // hard coded for devices with 480x800 (edge1050)
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if (dx != 480 || dy != 800)
       {
          singleDF = false;
       }else
       {
          singleDF = true;
       }
       ptGeom(dc, 120);
       landsc = false;
       return;
    }

    (:ed550)
    function onLayout(dc)
    {
       // hard coded for devices with 420x600 (edge550, edge850)
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if (dx != 420 || dy != 600)
       {
          singleDF = false;
       }else
       {
          singleDF = true;
       }
       ptGeom(dc, 90);
       landsc = false;
       return;
    }

    (:edmtb)
    function onLayout(dc)
    {
       // hard coded for devices with 240x320 (edgemtb)
       dx=dc.getWidth();
       dy=dc.getHeight();
       mx = dx>>1;
       my = dy>>1;
       if (dx != 240 || dy != 320)
       {
          singleDF = false;
       }else
       {
          singleDF = true;
       }
       ptGeom(dc, 50);
       landsc = false;
       return;
    }

    // The given info object contains all the current workout information.
    // Calculate a value and save it locally in this method.
    // Note that compute() and onUpdate() are asynchronous, and there is no
    // guarantee that compute() will be called before onUpdate().
    function compute(info)
    {
       if( info != null)
       {
          heading = info.currentHeading;
          var haveHdg = (heading != null);
          if(!haveHdg)
          {
             heading = 0.0;
          }

          // Track-up orientation. GPS heading is unreliable when stopped, so we
          // only adopt a new target while actually moving; otherwise the map
          // holds its last orientation. dispHdg eases toward the target so turns
          // glide instead of snapping.
          var spd = info.currentSpeed;
          if (haveHdg && (spd != null) && (spd >= 1.0))
          {
             tgtHdg = heading;
          }
          var dh = tgtHdg - dispHdg;
          while (dh >  3.141592653589793) { dh -= 6.283185307179586; }
          while (dh < -3.141592653589793) { dh += 6.283185307179586; }
          dispHdg += dh * 0.25;

          if (info.currentLocation != null)
          {
             var ddgr = info.currentLocation.toDegrees();
             var dgr = [ddgr[0].toFloat(), ddgr[1].toFloat()];
             var i= 0;
             if(!initialized)
             {
                pt.set(0,dgr);
                //cpt.set(0,dgr);
                cpt.l=-1;
                mp.newTiles = 0;
                mp.newTilesR= 0;
                initialized=true;
                mp.loni = 16385; // to force a map update
                dispHdg = heading; // snap orientation on first fix
                tgtHdg = heading;
             }

             if( pxdist(dgr,pt.getDeg(null)) )
             {
                pt.add(dgr);
             }
             if( mp.setMap(dgr[1],dgr[0]) )
             {
                cpt.add(dgr);
                mp.setTiles(cpt.p,cpt.l);
                cpt.save();
                //Storage.setValue eats mem like crazy, free some up before saving...
                cpt.p = null;
                pt.p = null;
                mp.save();
                cpt.load();
                pt.p = new[100];
                pt.set(0,dgr);
             }
          }
       }
    }


    function fgbgCol(dc, col1, col2)
    {
       if(getBackgroundColor()==Gfx.COLOR_BLACK)
       {
          dc.setColor(col1,Gfx.COLOR_BLACK);
       }else
       {
          dc.setColor(col2,Gfx.COLOR_WHITE);
       }
    }


    // "You are here" marker: a small black+white dot with a pulsing halo ring.
    // Black/white so it stands out on any tile colour. The pulse is
    // driven by the system clock (data fields only redraw at ~1Hz, so it throbs
    // rather than animating smoothly); ~3s period gives a visible step each draw.
    function plotMarker(dc, x, y)
    {
       var t = Sys.getTimer() / 1000.0;                 // seconds since boot
       var ph = (Math.sin(t * 2.094395102) + 1.0) / 2.0; // 0..1, ~3s period
       var base = dts / 4;                              // dot radius, tile-scaled
       if (base < 4)  { base = 4; }
       if (base > 12) { base = 12; }
       var ring = (base + 2 + ph * base).toNumber();    // expanding halo radius

       // pulsing halo: white ring with a black edge so it reads on any tile
       dc.setPenWidth(2);
       dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_TRANSPARENT);
       dc.drawCircle(x, y, ring + 1);
       dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
       dc.drawCircle(x, y, ring);
       dc.setPenWidth(1);

       // solid centre dot: white fill, black outline
       dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
       dc.fillCircle(x, y, base);
       dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_TRANSPARENT);
       dc.drawCircle(x, y, base);
    }


    // filled arrow (head + shaft/tail) centered at (cx,cy), total length 2*len,
    // pointing at bearing ang (radians, 0 = up/north, increasing clockwise)
    function dirArrow(dc, cx, cy, ang, len, col)
    {
       var fx = Math.sin(ang);
       var fy = -Math.cos(ang);
       var px = -fy;            // perpendicular (cos ang)
       var py = fx;             //               (sin ang)
       var hw = len * 0.60;     // head half-width
       var sw = len * 0.22;     // shaft half-width
       var ub = len - len * 0.85; // u of head base / shaft front
       dc.setColor(col, getBackgroundColor());
       dc.fillPolygon([
          [Math.round(cx + len*fx).toNumber(),         Math.round(cy + len*fy).toNumber()],          // tip
          [Math.round(cx + ub*fx + hw*px).toNumber(),  Math.round(cy + ub*fy + hw*py).toNumber()],   // right barb
          [Math.round(cx + ub*fx + sw*px).toNumber(),  Math.round(cy + ub*fy + sw*py).toNumber()],   // right shaft front
          [Math.round(cx - len*fx + sw*px).toNumber(), Math.round(cy - len*fy + sw*py).toNumber()],  // right tail
          [Math.round(cx - len*fx - sw*px).toNumber(), Math.round(cy - len*fy - sw*py).toNumber()],  // left tail
          [Math.round(cx + ub*fx - sw*px).toNumber(),  Math.round(cy + ub*fy - sw*py).toNumber()],   // left shaft front
          [Math.round(cx + ub*fx - hw*px).toNumber(),  Math.round(cy + ub*fy - hw*py).toNumber()]]); // left barb
    }


    function fmtDist(m)
    {
       if (Sys.getDeviceSettings().distanceUnits == Sys.UNIT_STATUTE)
       {
          if (m * 3.28084 < 1000.0) { return (m * 3.28084).format("%.0f") + "ft"; }
          return (m / 1609.344).format("%.1f") + "mi";
       }
       if (m < 1000.0) { return m.format("%.0f") + "m"; }
       return (m / 1000.0).format("%.1f") + "km";
    }


    // Find the nearest never-visited tile from the current position and cache
    // its heading-relative bearing (navAng) and distance string (navDist).
    // Both the direction and distance use the tile's NEAREST POINT, so the tile
    // you're about to ride into wins and the distance is "how far until I'm in it".
    function computeNav()
    {
       var rad = mp.clat * 0.0174532925199433;
       var cfx = (mp.clon + 180.0) * 45.5111111111111;
       var cfy = 8192.0 - Math.ln(Math.tan(rad) + 1.0 / Math.cos(rad)) * 2607.59458761762;
       navNt = mp.nearestNewTile(cfx, cfy);
       if (navNt == null) { navDist = ""; return; }

       // nearest point of the tile to the current position
       var npx = cfx;
       if (cfx < navNt[0])     { npx = navNt[0]; }
       else if (cfx > navNt[0] + 1) { npx = navNt[0] + 1; }
       var npy = cfy;
       if (cfy < navNt[1])     { npy = navNt[1]; }
       else if (cfy > navNt[1] + 1) { npy = navNt[1] + 1; }

       var ex = npx - cfx;            // east component, in tiles
       var sy = npy - cfy;            // south component, in tiles
       // bearing clockwise from north, minus the displayed map orientation, so
       // the arrow matches the rotated (track-up) grid -> straight up = ahead
       navAng = Math.atan2(ex, -sy) - dispHdg;
       navDist = fmtDist(Math.sqrt(ex * ex + sy * sy) * 40075016.686 * Math.cos(rad) / 16384.0);
    }


    (:header)
    function header(dc)
    {
       dc.setClip(tx[0],0,dx,ty[0]);

       dc.drawText(mx, ty[0]/4, Gfx.FONT_SMALL,
              "new: "+mp.newTiles.format("%i")+", tot: "+mp.newTilesR.format("%i"),
              Gfx.TEXT_JUSTIFY_CENTER);

       dc.setClip(tx[0],ty[0],dx,dy-ty[0]);
    }

    (:headerV)
    function header(dc)
    {
       if(landsc==true)
       {
           dc.setClip(0,0,tx[0],dy);
           dc.drawText(tx[0]/2, dy/4-16, Gfx.FONT_TINY, "New Tiles",Gfx.TEXT_JUSTIFY_CENTER);
           dc.drawText(tx[0]/2, dy/4, Gfx.FONT_MEDIUM,
              mp.newTiles.format("%i"),Gfx.TEXT_JUSTIFY_CENTER);
           dc.drawText(tx[0]/2, dy/2-16, Gfx.FONT_TINY, "Tiles Crossed",Gfx.TEXT_JUSTIFY_CENTER);
           dc.drawText(tx[0]/2, dy/2, Gfx.FONT_MEDIUM,
              mp.newTilesR.format("%i"),Gfx.TEXT_JUSTIFY_CENTER);

           dc.drawText(tx[0]/2, 3*dy/4-32, Gfx.FONT_TINY, "Closest",Gfx.TEXT_JUSTIFY_CENTER);
           dc.drawText(tx[0]/2, 3*dy/4-19, Gfx.FONT_TINY, "New Tile",Gfx.TEXT_JUSTIFY_CENTER);
           if (navNt == null)
           {
              fgbgCol(dc,Gfx.COLOR_WHITE,Gfx.COLOR_BLACK);
              dc.drawText(tx[0]/2, 3*dy/4+4, Gfx.FONT_TINY, "--",Gfx.TEXT_JUSTIFY_CENTER);
           }
           else
           {
              dirArrow(dc, tx[0]/2, 3*dy/4+12, navAng, 16, Gfx.COLOR_ORANGE);
              fgbgCol(dc,Gfx.COLOR_WHITE,Gfx.COLOR_BLACK);
              dc.drawText(tx[0]/2, 3*dy/4+30, Gfx.FONT_TINY, navDist, Gfx.TEXT_JUSTIFY_CENTER);
           }

           dc.setClip(tx[0],0,dx-tx[0],dy);
        }else
        {
           dc.setClip(tx[0],0,dx,ty[0]);

           var fhM = dc.getFontHeight(Gfx.FONT_MEDIUM);
           var pad = 4;

           fgbgCol(dc,Gfx.COLOR_WHITE,Gfx.COLOR_BLACK);
           var s1 = "New Tiles: "+mp.newTiles.format("%i");
           var s2 = "Tiles Crossed: "+mp.newTilesR.format("%i");
           var s3 = (navNt == null) ? "Closest New Tile: --" : "Closest New Tile: "+navDist;

           dc.drawText(pad, 2,        Gfx.FONT_MEDIUM, s1, Gfx.TEXT_JUSTIFY_LEFT);
           dc.drawText(pad, 2+fhM,    Gfx.FONT_MEDIUM, s2, Gfx.TEXT_JUSTIFY_LEFT);
           dc.drawText(pad, 2+2*fhM,  Gfx.FONT_SMALL,  s3, Gfx.TEXT_JUSTIFY_LEFT);

           if (navNt != null)
           {
              // widest text row, so the arrow stays clear of it
              var w1 = dc.getTextWidthInPixels(s1, Gfx.FONT_MEDIUM);
              var w2 = dc.getTextWidthInPixels(s2, Gfx.FONT_MEDIUM);
              var w3 = dc.getTextWidthInPixels(s3, Gfx.FONT_SMALL);
              var maxR = w1;
              if (w2 > maxR) { maxR = w2; }
              if (w3 > maxR) { maxR = w3; }
              maxR += pad;

              var availHalf = (dx - maxR - 10) / 2;   // horizontal room on the right
              var heightHalf = ty[0] / 2 - 4;         // vertical room in the header
              var aLen = (availHalf < heightHalf) ? availHalf : heightHalf;
              if (aLen > 6)
              {
                 dirArrow(dc, dx - aLen - 6, ty[0]/2, navAng, aLen, Gfx.COLOR_ORANGE);
              }
           }

           dc.setClip(tx[0],ty[0],dx,dy-ty[0]);
        }
    }

    // Display the value you computed here. This will be called
    // once a second when the data field is visible.
    function onUpdate(dc) {
        fgbgCol(dc,Gfx.COLOR_WHITE,Gfx.COLOR_BLACK);

        //this data field works only in 1-datafield layout
        if(singleDF==true)
        {
           var i=0;
           var ry=0;
           var cc=0;

           computeNav();      // nearest new tile -> navNt / navAng / navDist
           header(dc);

           // ---- track-up map: rider centred, direction of travel points up ----
           var nv = chooseZoom();
           var mapTop = ty[0];
           var mapH = dy - mapTop;
           // Size tiles to the SHORTER edge so nv tiles fit the inscribed circle:
           // the target then stays on screen whatever way the map is rotated.
           var minEdge = (mapH < dx) ? mapH : dx;
           dts = minEdge / nv;                    // square display tile size
           pcx = dx / 2;                          // rider pinned at the centre...
           pcy = mapTop + mapH / 2;               // ...of the map area
           ch = Math.cos(dispHdg);                // rotation by -dispHdg
           sh = Math.sin(dispHdg);

           // rider's fractional tile coords = the rotation pivot
           rfx = (mp.clon + 180.0) * 45.5111111111111;
           var rad = mp.clat * 0.0174532925199433;
           rfy = 8192.0 - Math.ln(Math.tan(rad) + 1.0 / Math.cos(rad)) * 2607.59458761762;

           // tiles each side needed to cover the screen out to its corners
           var rng = (Math.sqrt(1.0*dx*dx + 1.0*mapH*mapH) / (2*dts)).toNumber() + 2;

           // unvisited (orange) fills the whole map area; paint the rest on top
           dc.setColor(COL_UNVIS, COL_UNVIS);
           dc.fillRectangle(0, mapTop, dx, mapH);

           // visited tiles (blue), rotated
           for(ry = -rng; ry <= rng; ry++)
           {
              for(cc = -rng; cc <= rng; cc++)
              {
                 if (mp.tileVisited(mp.loni + cc, mp.lati + ry) == 1)
                 {
                    fillTile(dc, mp.loni + cc, mp.lati + ry, COL_VIS);
                 }
              }
           }

           // tiles touched this ride -> bright cyan (from the coarse path)
           for(i = 0; i <= cpt.l; i++)
           {
              var rt = cpt.getDeg(i);
              if (rt == null) { continue; }
              cc = mp.lon2loni(rt[1]) - mp.loni;
              ry = mp.lat2lati(rt[0]) - mp.lati;
              if ((cc >= -rng) && (cc <= rng) && (ry >= -rng) && (ry <= rng))
              {
                 fillTile(dc, mp.loni + cc, mp.lati + ry, COL_RIDE);
              }
           }

           // grid lines, in the background colour (like the gaps upstream left)
           var gx0 = mp.loni - rng;  var gx1 = mp.loni + rng + 1;
           var gy0 = mp.lati - rng;  var gy1 = mp.lati + rng + 1;
           var ga;  var gb;  var g;
           dc.setColor(getBackgroundColor(), getBackgroundColor());
           for(g = gx0; g <= gx1; g++)
           {
              ga = fpx(g, gy0);  gb = fpx(g, gy1);
              dc.drawLine(ga[0], ga[1], gb[0], gb[1]);
           }
           for(g = gy0; g <= gy1; g++)
           {
              ga = fpx(gx0, g);  gb = fpx(gx1, g);
              dc.drawLine(ga[0], ga[1], gb[0], gb[1]);
           }

           // track (fine + coarse path), then the rider marker on top
           var px = deg2px([mp.clat,mp.clon]);
           var lpx = px[0];
           var lpy = px[1];

           dc.setPenWidth(2);
           fgbgCol(dc,Gfx.COLOR_DK_GRAY,Gfx.COLOR_BLACK);
           for(i=pt.l-1; i>=0; i--)
           {
              px = deg2px(pt.getDeg(i));
              dc.drawLine(lpx, lpy, px[0], px[1]);
              lpx=px[0];
              lpy=px[1];
           }

           fgbgCol(dc,Gfx.COLOR_DK_GRAY,Gfx.COLOR_DK_GRAY);
           for(i=cpt.l; i>=0; i--)
           {
              px = deg2px(cpt.getDeg(i));
              dc.drawLine(lpx, lpy, px[0], px[1]);
              lpx=px[0];
              lpy=px[1];
           }
           dc.setPenWidth(1);

           // "you are here" marker at screen centre (a pulsing black/white dot)
           plotMarker(dc, pcx, pcy);
         }else
         {
            dc.setClip(0,0,dx,dy);
            dc.drawText(dx/2,5,Gfx.FONT_MEDIUM,Ui.loadResource(Rez.Strings.wholeDisp),Gfx.TEXT_JUSTIFY_CENTER);
         }

    }

}
