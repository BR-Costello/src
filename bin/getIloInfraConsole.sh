#!/bin/bash 
#   
# BSD 3-Clause License
#
# Copyright (c) 2025, BR-Costello brianspm@jbrcostello.com
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# 	An example showing automation for accessing a server over ssh into a remote management host and then into the ilo of 
# 	   the machine when networking is offline, side channel
# 	   If it is able to access the ilo, it will try to use the console password, obtained from the vault service 
# 	   and it will drop you into an interactive root shell.
# 	   If the parameters are correct, this should succeed, however it requires extensive customization with respect
# 	   to the particular environment. In other words, DO NOT EXECUTE ON PRODUCTION!!
# 	   Also, do not execute until you have a good idea what the code does.
#
#	This script will try to log into the Lights Out Management (LOM) interface of a host using vault passwords
#	   and if that is successful, it will attempt to log you into the console using the vault password for the console
#	   providing an interactive shell to the user.
#	   In both authn cases, it will try "default" passwords as provided from the vault.
#	   For the LOM/ILO it will also try the factory default, ie. to assist with recent MOBO replacements.
#
#	Use this, for example, when a server crashes and is not accessible via normal network traffic, it will automate
#	   authentication processes via lights out management interfaces allowing for very fast remediation.
#
#	It does not display any passwords on the command line
#
#	Prerequisites for the management server: bash4, Expect (tcl), ssh with connectivity to the management host's lights out management
#          Expect is usually distributed with RHEL, BSD-like environments, Solaris, Darwin 
#	   local ssh: ~/.ssh/config file with automatic ssh through a bastion and into a regional management host
#
#       I have an example written in python as well, but this method has shown better reliability
#

prefix="btrfs"

# Command or procedure required to retrieve the passwords securely.
# Password retrieval method varies widely among platform, this example uses a cloud vault service for managing secrets
#vaultCmd="/path/to/command/getSecrets.py"
vaultCmd="getSecrets.py"

# iloUser will be admin or root or sys
iloUser="admin"

#factoryDefaultPassword="cantgetin"
factoryDefaultPassword="cantgetin"

# This will need to be tailored to your specific environment
# Grab the standard password, and the default password if the current password is not set to the expected value
# password=\$($vaultCmd --action=get --secretName=${prefix}-\${target}-$iloUser); password2=\$($vaultCmd --action=get --secretName=${prefix}-default);
# consolePass=\$($vaultCmd --action=get --secretName=${prefix}-\$target-root);
#

function iloTryToGetConsole() {

  local myTarget=$1
  local regionAD=${myTarget:0:4} # <- This will determine the region that the management host lives in

  # The long command below pipes the expect code into the endpoint and executes it there
  ssh -t ${regionAD}mgmt "sudo -u root -- sh -c 'cd; NODE=${myTarget}; ILO=${myTarget/\./lom.}; SHORTNODE=${myTarget/.*/}
    echo NODE=\$NODE SHORTNODE=\$SHORTNODE ILO=\$ILO; 

    # Remove these comments from the ssh command prior to running, if there are any issues
    # Get the passwords, the below stanza grabs: 
    # 1. expected password for the ilo
    # 2. generic password for the ilo if the expected password isn't working
    # 3. factory default password for the ilo if it has not yet been set (motherboard replacement)
    # 4. console password for the system which may be stuck in single user mode
    
    password=\$($vaultCmd --action=get --secretName=${prefix}-ilo-$iloUser) 
    password2=\$($vaultCmd --action=get --secretName=${prefix}-default)
    consolePass=\$($vaultCmd --action=get --secretName=${prefix}-root)

    /usr/bin/expect -c \"set pwlist [list \$password \$password2 \$factoryDefaultPassword \$consolePass]; set timeout 30;
      for {set index 0} {\\\$index < [llength \\\$pwlist]} {incr index} {
        spawn ssh -o ConnectTimeout=7 ${iloUser}@\$ILO 
        expect {
          \\\"assword: \\\" { 
            send -- \\\"[lindex \\\$pwlist \\\$index]\\r\\\"; 
            expect  { 
              \\\".*> \\\" { 
	        send -- \\\"console-view; connect interconnect EM1FFFF101 1 1 \\r\\\";
                expect -re \\\".* ESC \\\"; send \\\"\\r\\\"; 
                expect { 
                  \\\"# \\\" { send_user \\\"You might be in, hit enter\\n\\\"; interact; break }
                  \\\"ogin: \\\" {
                    send \\\"$iloUser\\r\\\"; expect \\\"assword: \\\"; send \\\"[lindex \\\$pwlist end]\\r\\\";
                    expect { 
                      \\\"$iloUser@\$SHORTNODE\\\" { send_user \\\"\\nFound root@\$SHORTNODE, should be interactive\\n\\\"; send \\\"\\r\\\"; interact; break } 
                      \\\"Last login: \\\" { send_user \\\"Found Last login, should be interactive\\n\\\"; interact; break }
                      \\\"login:\\\" { 
                        send \\\"root\\r\\\"; 
                        expect \\\"assword:\\\"; 
                        send \\\"[lindex \\\$pwlist 1]\\r\\\" ; 
                        expect \\\"# \\\"; send_user \\\"\\n **** This system is using the default password for root login, please fix it **** \\n\\\"; send \\\"\\r\\\"; interact; break
                      }
                      timeout { send_user \\\"timed out, dropping to ilo\\\"; send \\\"\\033(\\\"; interact; break }
                  }
                  timeout { send_user \\\"timed out, dropping to ilo\\\"; send \\\"\\033(\\\"; interact ; break }
                }
                timeout { send_user \\\"timed out, dropping to ilo\\\"; send \\\"\\033(\\\"; interact ; break }
              }
              \\\"assword:\\\" {send_user \\\"\\n\\\"; close; catch wait result; continue}
            }
            \\\"assword:\\\" {send_user \\\"\\n\\\"; close; catch wait result; continue}
          }
          }
          \\\"yes/no)?\\\"  { send \\\"yes\\r\\\"; set index -1; continue } 
	  \\\"ssh: Could not resolve hostname\\\"  { send_user \\\"Check the hostname and try again\\n\\\"; interact; break } 
          \\\"Connection refused\\\" { set index -1; sleep 7; continue } 
          \\\"Connection timed out\\\" { set index -1; continue } 
	  \\\"Offending RSA key in\\\" { send_user \\\"correcting ssh key in ~/.known_hosts\\n\\\"; send \\\"ssh-keygen -R \$ILO\\r\\\"; set index -1; continue } 
          \\\"password\\\" { close; continue }
	  timeout { send_user \\\"timed out, dropping to interactive\\\"; interact; break }
       }
     
    }
    if {[string length \\\$spawn_id] != 0} {
      catch wait result
    }
  \"; 
  HOST=$myTarget ILO=${myTarget/\./lo.} NODE=$NODE bash -l'" # <-- This provides a bash session on the management server for additional debugging.
  
}

# Main ()

HOST=$1
iloTryToGetConsole $HOST

exit 0

# Ignore below:
# bigLongSha256sumString run: tail -1 thisfile;  cat thisfile | head -n -1 | sha256sum should display the file, otherwise it has been altered
