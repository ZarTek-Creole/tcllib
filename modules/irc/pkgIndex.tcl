# pkgIndex.tcl -*- tcl -*-
if { ![package vsatisfies [package provide Tcl] 8.6] } {
    # PRAGMA: returnok
    return
}
package ifneeded irc     0.7.0 [list source [file join $dir irc.tcl]]
package ifneeded picoirc 0.9.2 [list source [file join $dir picoirc.tcl]]
