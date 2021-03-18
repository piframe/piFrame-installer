#!/usr/bin/env bash
# https://die-antwort.eu/techblog/2017-12-setup-raspberry-pi-for-kiosk-mode
{ # this ensures the entire script is downloaded #

if [ "$(id -u)" != "0" ]; then
echo "Sorry, you are not root."
exit 1
fi

#lifted from openframe.io
piframe_edit_or_add() {
  if grep -q "^$2" $1; then
    sudo bash -c "sed -i 's/^$2.*/$2$3/g' $1"
  else
    sudo bash -c "echo $2$3 >> $1"
  fi
}

#lifted from openframe.io
piframe_do_rotate() {
  echo "how much have you rotated it?"
  echo "enter '0' for no rotation"
  echo "'1' if you rotated your physical screen 90 degrees clockwise"
  echo "'2' for 180 degrees (upside down)"
  echo "'3' for 270 degrees (90 degrees counter-clockwise)"
  read ANSWER
  if [ "$ANSWER" -ge 0 -a "$ANSWER" -le 3 ]; then
    piframe_edit_or_add /boot/config.txt display_rotate= $ANSWER
  else
    echo "input not recognised, must be a number between 0 and 3"
    piframe_ask_rotate
  fi
}

#lifted from openframe.io
piframe_ask_rotate() {
  echo "have you rotated your screen from default (normally landscape)? (y/n)"
  read ANSWER
  ANSWER="$(echo $ANSWER | tr '[:upper:]' '[:lower:]')"
  if [ "$ANSWER" == "y" ] || [ "$ANSWER" == "yes" ]; then
    piframe_do_rotate
  elif [ "$ANSWER" == "n" ] || [ "$ANSWER" == "no" ]; then
    :
  else
    echo "input not recognised, must be yes or no"
    piframe_ask_rotate
  fi
}


# configure the nginx 
nginx_do_config() {
	cat > /etc/nginx/sites-available/piframe.conf << EOF
upstream django {
  server 127.0.0.1:8000;
}
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;

    # Add index.php to the list if you are using PHP
    index index.html index.htm index.nginx-debian.html;

    server_name _;

    charset     utf-8;

    # max upload size
    client_max_body_size 75M;   # adjust to taste

    # Django media
    location /media  {
            alias /opt/piFrame/media;  # your Django project's media files - amend as required
    }

    location /static {
            alias /opt/piFrame/static; # your Django project's static files - amend as required
    }

    # Finally, send all non-media requests to the Django server.
    location / {
            uwsgi_pass  django;
            include     /opt/piFrame/uwsgi_params;
    }
}
EOF
	ln -s /etc/nginx/sites-available/piframe.conf /etc/nginx/sites-enabled/piframe.conf
	rm -rf /etc/nginx/sites-enabled/default
	systemctl restart nginx restart
}

#Optional Tools
optional_tools_do_install() {
  echo "install vim"
	apt-get install vim -y

  echo "install screen"
  apt-get install screen -y
}

piframe_configure_pi(){
  # if gpu_mem is not set, set gpu memory to 96
  grep -qxF 'gpu_mem=' /boot/config.txt || echo 'gpu_mem=96' >> /boot/config.txt

  # if display rotate is not set, set display rotate to 1 
  # grep -qxF 'display_rotate=' /boot/config.txt || echo 'display_rotate=1' >> /boot/config.txt
}

openbox_do_config(){
# configure the openbox 
cat > /etc/xdg/openbox/autostart << EOF
# Disable any form of screen saver / screen blanking / power management
xset s off
xset s noblank
xset -dpms

# Allow quitting the X server with CTRL-ATL-Backspace
setxkbmap -option terminate:ctrl_alt_bksp

# Start Chromium in kiosk mode
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/'Local State'
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]\+"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences
chromium-browser --disable-infobars --kiosk 'http://127.0.0.1/display/'
EOF
}

piframe_splashscreen_config(){
# configure the openbox 
cat > /etc/systemd/system/splashscreen.service << EOF
# /etc/systemd/system/splashscreen.service

[Unit]
Description=splashScreen
DefaultDependencies=no
After=local-fs.target

[Service]
ExecStart=/usr/bin/fbi -d /dev/fb0 --noverbose -a /opt/piFrame/.logo/splash.png
StandardInput=tty
StandardOutput=tty

[Install]
WantedBy=sysinit.target
EOF
systemctl enable splashscreen.service
}

piframe_uwsgi_config(){
# configure the openbox 
cat > /etc/systemd/system/piframe.service << EOF
# piframe.service

[Unit]
Description=piFrame

# Requirements
Requires=network.target

# Dependency ordering
After=network.target

[Service]
TimeoutStartSec=0
RestartSec=10
Restart=always

# path to app
WorkingDirectory=/opt/piFrame
# the user that you want to run app by
User=www-data
Group=www-data

KillSignal=SIGQUIT
Type=notify
NotifyAccess=all

# Main process
ExecStart=/usr/local/bin/uwsgi --close-on-exec --socket :8000 --module piframe.wsgi

[Install]
WantedBy=multi-user.target
EOF
systemctl enable piframe.service
systemctl start piframe.service
}

piframe_do_autologin(){

# configure the openbox 
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I 38400 linux
EOF

# add command to bash profile
cat > /home/pi/.bash_profile <<'EOF'
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && startx -- -nocursor
EOF

#change owner to pi
chown -R pi:pi /home/pi/.bash_profile

# disable the login prompt
#systemctl disable getty@tty1
}

piframe_do_hostname(){
  random=$(LC_CTYPE=C tr -d -c 'a-z0-9' </dev/urandom | head -c 6)
  HOSTN="piframe-${random}"
  HOSTN="s/raspberrypi/${HOSTN}/g"

  sed -i "${HOSTN}" /etc/hosts
  sed -i "${HOSTN}" /etc/hostname
}

piframe_do_install() {
  # disable terminal screen blanking
  piframe_edit_or_add /home/pi/.bashrc "setterm -powersave off -blank 0"

	# update the system
	echo "update system"
	apt-get update

	echo "upgrade system packages"
	apt-get upgrade -y

	# add the necessary packages
	echo "install server x11 utils"
	apt-get install xserver-xorg x11-xserver-utils xinit openbox -y

	echo "install chromium"
	apt-get install chromium-browser -y

  echo "install python tools"
  apt-get install python3-dev python3-setuptools -y

  echo "install pip3"
  apt-get install python3-pip -y

  echo "libjpg"
  apt-get install libjpeg-dev -y

  echo "libopenjp2-7"
  apt-get install libopenjp2-7 -y

  echo "install git"
  apt-get install git -y

  echo "install Nginx"
  apt-get install nginx -y

  echo "configure openbox"
  openbox_do_config

  echo "install optional tools"
  optional_tools_do_install

	echo "install piframe"
	echo "cloning piframe repo"
	git clone https://github.com/adriangoris/piFrame /opt/piFrame

	echo "installing python modules"
	pip3 install -r /opt/piFrame/requirements.txt
  
	echo "creating and configuring database"
	python3 /opt/piFrame/manage.py migrate

  echo "change permissions of directory"
  chown -R www-data:www-data /opt/piFrame

  echo "install nginx"
  nginx_do_config

  echo "install uwsgi"
  pip3 install uwsgi

  echo "configure piframe systemctl"
  piframe_uwsgi_config

  piframe_do_hostname

  # disable the Raspberry Pi ‘color test’ 
  piframe_edit_or_add /boot/config.txt "disable_splash=1"

  # disable the Raspberry Pi logo in the corner of the screen
  piframe_edit_or_add /boot/cmdline.txt "logo.nologo"

  # disable kernel messages
  piframe_edit_or_add /boot/cmdline.txt "consoleblank=0"
  piframe_edit_or_add /boot/cmdline.txt "loglevel=1"
  piframe_edit_or_add /boot/cmdline.txt "quiet"
  piframe_edit_or_add /boot/cmdline.txt "disable_overscan=0"

  #autologin
  piframe_do_autologin

  # interactive prompt for configuration
  piframe_ask_rotate

  echo ""
  echo "If you have changed your display rotation, you must restart the Pi by typing: sudo reboot"
  echo ""
  echo "If not, you must run the following command: source ~/.bashrc"
  echo ""
  echo "After restarting or reloading .bashrc, you can launch the frame by just typing:"
  echo ""
  echo "piframe"

}

piframe_do_install


reboot


} # this ensures the entire script is downloaded #