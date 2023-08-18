#!/usr/bin/env bash 
#Exits script on error or undefined variable 
set -euo pipefail
#Check if running as sudo
if [ $EUID == 0 ]
then
    echo "standby"
    sleep 10
else
    echo "run as sudo"
    exit 2
fi

#define variables
echo "number 1-5 based on the type of install"
echo "0-5 0 is just update, no configuration, 1 is headless server, 2 is vpn headless server, 3 is netbook, 4 is desktop, 5 is vps"
#var 1 is install reference
read -r -n 1 var1
echo " " 
echo "install tailscale y or n"
#var 2 is installing tail scale
read -r -n 1 var2
echo " "
echo "reboot upon completion?"
echo "Y or N"
#var 3 is for autoreboot upon script completion
read -r -n 1 var3
echo " "
#inistal system stup, bisic tools and full update
echo "begenning setup standby" 
apt -y update
apt -y upgrade
# install utils
apt -y install openssh-server tmux wget git curl software-properties-common
#ssh pubkey pull
echo pulling ssh keys
#wget 
#this is where it dynamicizes from the basic install
if [ "$var1" == 1 ]  
#headless server
then 
    apt install -y easyrsa arp-scan
elif [ "$var1" == 2 ]
then 
    apt install -y openvpnheadless server easyrsa arp-scan
elif [ "$var1" == 3 ]
#netbook
then 
    add-apt-repository ppa:vantuz/cool-retro-term
    apt update
    apt install -y i3 i3lock lightdm cool-retro-term compton xscreensaver xscreensaver-data xscreensaver-data-extra
elif [ "$var1" == 4 ]
#desktop
then 
    add-apt-repository ppa:vantuz/cool-retro-term
    apt update
    apt install -y i3 i3lock lightdm cool-retro-term compton xscreensaver xscreensaver-data xscreensaver-data-extra 
elif [ "$var1" == 5 ]
#vps 
then 
    apt install openvpn 
elif [ "$var1" == 0 ]
#just update aind install packages default to system
then
    apt update -y
    apt upgrade -y
fi
#install tailscale segment 
if [ "$var2" == y ]
then
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
apt update
apt install tailscale
else
echo tailscale install bypassed, continuing 
fi
#install configs from github
#echo "installing config"

#alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME '
#dotfiles clone --bare https://github.com/avetruvio/config.git ~/.dotfiles
#dotfiles checkout
#dotfiles config --local status.showUntrackedFiles no

#dotfiles attempt 1
#install configs from github
#echo "installing config"
#rm .bashrc
#rm .profile

#dotfiles() {
#    /usr/bin/git --git-dir="$HOME"/.dotfiles/ --work-tree="$HOME"
#
#}

#dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME '
#dotfiles clone --bare https://github.com/avetruvio/config.git ~/.dotfiles
#dotfiles checkout
#dotfiles config --local status.showUntrackedFiles no



#dotfiles attempt 2

echo "installing config"

# Remove the existing .bashrc and .profile files if necessary
rm -f ~/.bashrc
rm -f ~/.profile

# Define the 'dotfiles' alias
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

# Clone the dotfiles into a bare repository
/usr/bin/git clone --bare https://github.com/avetruvio/config.git $HOME/.dotfiles

# Checkout the actual files in your home directory
dotfiles checkout

# If the checkout command produces an error due to pre-existing files,
# the script will remove the conflicting files and re-run the checkout command
if [ $? != 0 ]; then
  echo "Removing pre-existing dot files."
  dotfiles checkout 2>&1 | egrep "\s+\." | awk {'print $1'} | xargs -I{} rm -f {}
  dotfiles checkout
fi

# Set the flag showUntrackedFiles to no on this specific (local) repository
dotfiles config --local status.showUntrackedFiles no


#needs to be finished later, gonna be a pain to do 


#remove any excess packages
apt autoremove -y 

#extra info for making ssh configs eaiser
sleep 3
{
echo "$HOSTNAME" 
ip a | grep "scope global"
echo "Hostanme"
whoami
} >> host-ini-info

echo "all info needed for ssh configuration is stored in the file in the home dir called host-ini-info"
scp host-ini-info amber@149.56.98.27:/host-config-files/



if [ "$var3" == y ]
then 
    echo "Setup Complete, Rebooting"
    sleep 7
    reboot now
else
echo "Setup Complete" 
fi 
#script is written by Avitruvio

