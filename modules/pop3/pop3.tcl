# pop3.tcl --
#
#	POP3 mail client package, written in pure Tcl.
#	Some concepts borrowed from "frenchie", a POP3
#	mail client utility written by Scott Beasley.
#
# Copyright (c) 2000 by Ajuba Solutions.
# portions Copyright (c) 2000 by Scott Beasley
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
# 
# RCS: @(#) $Id: pop3.tcl,v 1.12 2001/08/02 16:38:07 andreas_kupries Exp $

package require Tcl 8.2
package require cmdline
package provide pop3 1.3

namespace eval ::pop3 {

    # The state variable remembers information about the open pop3
    # connection. It is indexed by channel id. The information is
    # a keyed list, with keys "msex" and "retr_mode". The value
    # associated with "msex" is boolean, a true value signals that the
    # server at the other end is MS Exchange. The value associated
    # with "retr_mode" is one of {retr, list, slow}.

    # The value of "msex" influences how the translation for the
    # channel is set and is determined by the contents of the received
    # greeting. The value of "retr_mode" is initially "retr" and
    # completely determined by the first call to [retr]. For "list" the
    # system will use LIST before RETR to retrieve the message size.

    # The state can be influenced by options given to "open".

    variable  state
    array set state {}

}

# pop3::open --
#
#	Opens a connection to a POP3 mail server.
#
# Arguments:
#       args     A list of options and values, possibly empty,
#		 followed by the regular arguments, i.e. host, user,
#		 passwd and port. The latter is optional.
#
#	host     The name or IP address of the POP3 server host.
#       user     The username to use when logging into the server.
#       passwd   The password to use when logging into the server.
#       port     (optional) The socket port to connect to, defaults
#                to port 110, the POP standard port address.
#
# Results:
#	The connection channel (a socket).
#       May throw errors from the server.

proc ::pop3::open {args} {
    variable state
    array set cstate {msex 0 retr_mode retr}

    while {[set err [cmdline::getopt args {msex.arg retr-mode.arg} opt arg]]} {
	if {$err < 0} {
	    return -code error "::pop3::open : $arg"
	}
	switch -exact -- $opt {
	    msex {
		if {![string is boolean $arg]} {
		    return -code error \
			    ":pop3::open : Argument to -msex has to be boolean"
		}
		set cstate(msex) $arg
	    }
	    retr-mode {
		switch -exact -- $arg {
		    retr - list - slow {
			set cstate(retr_mode) $arg
		    }
		    default {
			return -code error \
				":pop3::open : Argument to -retr-mode has to be one of retr, list or slow"
		    }
		}
	    }
	    default {# Can't happen}
	}
    }

    if {[llength $args] > 4} {
	return -code error "To many arguments to ::pop3::open"
    }
    if {[llength $args] < 3} {
	return -code error "Not enough arguments to ::pop3::open"
    }
    foreach {host user password port} $args break
    if {$port == {}} {
	set port 110
    }

    # Argument processing is finally complete, now open the channel

    set chan [socket $host $port]
    fconfigure $chan -buffering none

    if {$cstate(msex)} {
	# We are talking to MS Exchange. Work around its quirks.
	fconfigure $chan -translation binary
    } else {
	fconfigure $chan -translation {binary crlf}
    }

    if {[catch {::pop3::send $chan {}} errorStr]} {
	error "POP3 CONNECT ERROR: $errorStr"
    }

    if {0} {
	# -FUTURE- Identify MS Exchange servers
	set cstate(msex) 1

	# We are talking to MS Exchange. Work around its quirks.
	fconfigure $chan -translation binary
    }

    if {[catch {
	    ::pop3::send $chan "user $user"
	    ::pop3::send $chan "pass $password"
        } errorStr]} {
	error "POP3 LOGIN ERROR: $errorStr"
    }

    # Remember the state.

    set state($chan) [array get cstate]
    return $chan
}

# ::pop3::status --
#
#	Get the status of the mail spool on the POP3 server.
#
# Arguments:
#	chan      The channel, returned by ::pop3::open
#
# Results:
#	A list containing two elements, {msgCount octetSize},
#       where msgCount is the number of messages in the spool
#       and octetSize is the size (in octets, or 8 bytes) of
#       the entire spool.

proc ::pop3::status {chan} {

    if {[catch {set statusStr [::pop3::send $chan "STAT"]} errorStr]} {
	error "POP3 STAT ERROR: $errorStr"
    }

    # Dig the sent size and count info out.
    set rawStatus [split [string trim $statusStr]]
    
    return [::list [lindex $rawStatus 0] [lindex $rawStatus 1]]
}

# ::pop3::last --
#
#	Gets the index of the last email read from the server.
#       Note, some POP3 servers do not support this feature,
#       in which case the value returned may always be zero,
#       or an error may be thrown.
#
# Arguments:
#	chan      The channel, returned by ::pop3::open
#
# Results:
#	The index of the last email message read, which may
#       be zero if none have been read or if the server does
#       not support this feature.
#       Server errors may be thrown, including some cases
#       when the LAST command is not supported.

proc ::pop3::last {chan} {

    if {[catch {
	    set resultStr [::pop3::send $chan "LAST"]
        } errorStr]} {
	error "POP3 LAST ERROR: $errorStr"
    }
    
    return [string trim $resultStr]
}

# ::pop3::retrieve --
#
#	Retrieve email message(s) from the server.
#
# Arguments:
#	chan      The channel, returned by ::pop3::open
#       start     The first message to retrieve in the range.
#                 May be "next" (the next message after the last
#                 one seen, see ::pop3::last), "start" (aka 1),
#                 "end" (the last message in the spool, for 
#                 retriving only the last message).
#       end       (optional, defaults to -1) The last message
#                 to retrieve in the range. May be "last"
#                 (the last message viewed), "end" (the last
#                 message in the spool), or "-1" (the default,
#                 any negative number means retrieve only
#                 one message).
#
# Results:
#	A list containing all of the messages retrieved.
#       May throw errors from the server.

proc ::pop3::retrieve {chan start {end -1}} {
    variable state
    array set cstate $state($chan)
    
    set count [lindex [::pop3::status $chan] 0]
    set last 0
    catch {set last [::pop3::last $chan]}

    if {![string is integer $start]} {
	if {[string match $start "next"]} {
	    set start $last
	    incr start
	} elseif {$start == "start"} {
	    set start 1
	} elseif {$start == "end"} {
	    set start $count
	} else {
	    error "POP3 Retrieval error: Bad start index $start"
	}
    } 
    if {$start == 0} {
	set start 1
    }
    
    if {![string is integer $end]} {
	if {$end == "end"} {
	    set end $count
	} elseif {$end == "last"} {
	    set end $last
	} else {
	    error "POP3 Retrieval error: Bad end index $end"
	}
    } elseif {$end < 0} {
	set end $start
    }

    if {$end > $count} {
	set end $count
    }
    
    set result {}

    for {set index $start} {$index <= $end} {incr index} {
	switch -exact -- $cstate(retr_mode) {
	    retr {
		set sizeStr [::pop3::send $chan "RETR $index"]

		if {[scan $sizeStr {%d %s} size dummy] < 0} {
		    # The server did not deliver the size information.
		    # Switch our mode to "list" and use the slow
		    # method this time. The next call will use LIST before
		    # RETR to get the size information. If even that fails
		    # the system will fall back to slow mode all the time.

		    set cstate(retr_mode) list
		    set state($chan) [array get cstate]

		    # Retrieve in slow motion.
		    set msgBuffer [RetrSlow $chan]
		} else {
		    set msgBuffer [RetrFast $chan $size]
		}
	    }
	    list {
		set sizeStr [::pop3::send $chan "LIST $index"]

		if {[scan $sizeStr {%d %d %s} dummy size dummy] < 0} {
		    # Not even LIST generates the necessary size information.
		    # Switch to full slow mode and don't bother anymore.

		    set cstate(retr_mode) slow
		    set state($chan) [array get cstate]

		    # Retrieve in slow motion.
		    set msgBuffer [RetrSlow $chan]
		} else {
		    # Ignore response of RETR, already know the size
		    # through LIST

		    ::pop3::send $chan "RETR $index"

		    set msgBuffer [RetrFast $chan $size]
		}
	    }
	    slow {
		# Retrieve in slow motion.

		set msgBuffer [RetrSlow $chan]
	    }
	}
	lappend result $msgBuffer
    }
    return $result
}

# ::pop3::RetrFast --
#
#	Fast retrieval of a message from the pop3 server.
#	Internal helper to prevent code bloat in "pop3::retrieve"
#
# Arguments:
#	chan	The channel to read the message from.
#
# Results:
#	The text of the retrieved message.

proc ::pop3::RetrFast {chan size} {
    set msgBuffer [read $chan $size]

    # We might have read not enough because of .-stuffed lines.
    # Read the possible remainder in line by line fashion!
    #		    
    # get the terminating "."
    # sometimes the gets returns nothing, 
    # need to get the real terminating "."

    while {[set line [gets $chan]] != ".\r"} {
	append msgBuffer $line
    }

    # Map both cr+lf and cr to lf to simulate auto EOL translation, then
    # unstuff .-stuffed lines.

    return [string map [list \n.. \n.] [string map [list \r \n] [string map [list \r\n \n] $msgBuffer]]]
}

# ::pop3::RetrSlow --
#
#	Slow retrieval of a message from the pop3 server.
#	Internal helper to prevent code bloat in "pop3::retrieve"
#
# Arguments:
#	chan	The channel to read the message from.
#
# Results:
#	The text of the retrieved message.

proc ::pop3::RetrSlow {chan} {
    set msgBuffer ""
	
    while {1} {
	set line [string trimright [gets $chan] \r]
	    
	# End of the message is a line with just "."
	if {$line == "."} {
	    break
	} elseif {[string index $line 0] == "."} {
	    set line [string range $line 1 end]
	}
		
	append msgBuffer $line "\n"
    }

    return $msgBuffer
}

# ::pop3::delete --
#
#	Delete messages on the POP3 server.
#
# Arguments:
#	chan      The channel, returned by ::pop3::open
#       start     The first message to delete in the range.
#                 May be "next" (the next message after the last
#                 one seen, see ::pop3::last), "start" (aka 1),
#                 "end" (the last message in the spool, for 
#                 deleting only the last message).
#       end       (optional, defaults to -1) The last message
#                 to delete in the range. May be "last"
#                 (the last message viewed), "end" (the last
#                 message in the spool), or "-1" (the default,
#                 any negative number means delete only
#                 one message).
#
# Results:
#	None.
#       May throw errors from the server.

proc ::pop3::delete {chan start {end -1}} {
    
    set count [lindex [::pop3::status $chan] 0]
    set last 0
    catch {set last [::pop3::last $chan]}

    if {![string is integer $start]} {
	if {[string match $start "next"]} {
	    set start $last
	    incr start
	} elseif {$start == "start"} {
	    set start 1
	} elseif {$start == "end"} {
	    set start $count
	} else {
	    error "POP3 Deletion error: Bad start index $start"
	}
    } 
    if {$start == 0} {
	set start 1
    }
	
    
    if {![string is integer $end]} {
	if {$end == "end"} {
	    set end $count
	} elseif {$end == "last"} {
	    set end $last
	} else {
	    error "POP3 Deletion error: Bad end index $end"
	}
    } elseif {$end < 0} {
	set end $start
    }

    if {$end > $count} {
	set end $count
    }
    
    for {set index $start} {$index <= $end} {incr index} {
	if {[catch {::pop3::send $chan "DELE $index"} errorStr]} {
	    error "POP3 DELETE ERROR: $errorStr"
	}
    }
    return {}
}

# ::pop3::close --
#
#	Close the connection to the POP3 server.
#
# Arguments:
#	chan      The channel, returned by ::pop3::open
#
# Results:
#	None.

proc ::pop3::close {chan} {
    variable state
    catch {::pop3::send $chan "QUIT"}
    unset state($chan)
    ::close $chan
}

		

# ::pop3::send --
#
#	Send a command string to the POP3 server.  This is an
#       internal function, but may be used in rare cases.
#
# Arguments:
#	chan        The channel open to the POP3 server.
#       cmdstring   POP3 command string
#
# Results:
#	Result string from the POP3 server, except for the +OK tag.
#       Errors from the POP3 server are thrown.

proc ::pop3::send {chan cmdstring} {
   global PopErrorNm PopErrorStr debug

   if {$cmdstring != {}} {
      puts $chan $cmdstring
   }
   
   set popRet [string trim [gets $chan]]

   if {[string first "+OK" $popRet] == -1} {
       error [string range $popRet 4 end]
   }

   return [string range $popRet 3 end]
}

# ::pop3::list --
#
#	Returns "scan listing" of the mailbox. If parameter msg
#       is defined, then the listing only for the given message 
#       is returned.
#
# Arguments:
#	chan        The channel open to the POP3 server.
#       msg         The message number (optional).
#
# Results:
#	If msg parameter is not given, Tcl list of scan listings in 
#       the maildrop is returned. In case msg parameter is given,
#       a list of length one containing the specified message listing
#       is returned.

proc ::pop3::list {chan {msg ""}} {
    global PopErrorNm PopErrorStr debug
 
    if {$msg == ""} {
	if {[catch {::pop3::send $chan "LIST"} errorStr]} {
	    error "POP3 LIST ERROR: $errorStr"
	}
	set msgBuffer {}
	while {1} {
	    set line [gets $chan]

	    # End of the message is a line with just "."

	    set line [string trimright $line]

	    if {$line == "."} {
		break
	    } elseif {[string index $line 0] == "."} {
		# Use trimright to ge rid of superfluous \r's
		# (we get them due to binary mode)

		set line [string range $line 1 end]
	    }

	    lappend msgBuffer $line
	}
    } else {
	# argument msg given, single-line response expected

	if {[catch {expr {0 + $msg}}]} {
	    error "POP3 LIST ERROR: malformed message number '$msg'"
	} else {
	    lappend msgBuffer [string trim [::pop3::send $chan "LIST $msg"]]
	}
    }
    return $msgBuffer
}

# ::pop3::top --
#
#       Optional POP3 command (see RFC1939). Retrieves message header
#       and given number of lines from the message body.
#
# Arguments:
#	chan        The channel open to the POP3 server.
#       msg         The message number to be retrieved.
#       n           Number of lines returned from the message body.
#
# Results:
#	Text (with newlines) from the server.
#       Errors from the POP3 server are thrown.

proc ::pop3::top {chan msg n} {
    global PopErrorNm PopErrorStr debug
    
    if {[catch {::pop3::send $chan "TOP $msg $n"} errorStr]} {
	error "POP3 TOP ERROR: $errorStr"
    }

    while {1} {
	set line [gets $chan]
	# End of the message is a line with just "."
	if {[string trimright $line] == "."} {
	    break
	} elseif {[string index $line 0] == "."} {
	    # Get rid of traling \r's. We get them due to binary mode.
	    set line [string trimright [string range $line 1 end]]
	}
	append msgBuffer "$line\n"
    }
    return $msgBuffer
}
