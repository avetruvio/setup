#!/usr/bin/env bash 
#Exits script on error or undefined variable 
set -euo pipefail
#Check if running as sudo
if [ $EUID == 0 ]
then
    echo "standby"

else
    echo "run as sudo"
    exit 2
fi

#define variable 
echo "number 1-4 based on the type of install"
echo "1-5 1 is headless server, 2 is vpn headless server, 3 is netbook, 4 is desktop, 5 is vps"
read -r -n 1 var1 

echo "begenning setup standby" 
#inistal system stup, bisic tools and full update
apt -y update
apt -y upgrade
# install utils
apt -y install openssh-server tmux wget git
#ssh pubkey pull
echo pulling ssh keys
wget 
#this is where it dynamicizes from the basic install
if [ "$var1" == 1 ]  
#headless server
then 
    apt install easyrsa arp-scan
elif [ "$var1" == 2 ]
#
then 
    apt install openvpnheadless server easyrsa arp-scan
elif [ "$var1" == 3 ]
#netbook
then 
    apt install i3 i3lock lightdm cool-retro-term compton i3-sensible-terminal xscreensaver xscreensaver-data xscreensaver-data-extra
elif [ "$var1" == 4 ]
#desktop
then 
    apt install i3 i3lock lightdm cool-retro-term compton  i3-sensible-terminal xscreensaver xscreensaver-data xscreensaver-data-extra 
elif ["$var1" == 5 ]
#vps 
then 
    apt install openvpn 
fi

#install configs from github
#echo "installing config"

#alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME '
#dotfiles clone --bare https://github.com/avetruvio/config.git ~/.dotfiles
#dotfiles checkout
#dotfiles config --local status.showUntrackedFiles no

#needs to be finished later, gonna be a pain to do 
