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
//! You should have received a copy of the GNU General Public License along
//! with this program. If not, see <http://www.gnu.org/licenses/>.

using Toybox.WatchUi as Ui;

// Forwards screen taps to the live data-field view so it can hit-test the
// on-screen zoom buttons. Registered alongside the view in
// EveryTilePlusApp.getInitialView(); only touch-capable devices ever deliver
// taps here.
class TouchDelegate extends Ui.BehaviorDelegate {
   function initialize() {
      BehaviorDelegate.initialize();
   }

   function onTap(evt) {
      handleZoomTap(evt);
      return true;
   }
}
