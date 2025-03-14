#!/bin/bash -eu

# based on https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

if [ -z "${AP_SSID+x}" ]
then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8))
then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

function nm_get_wifi_client_device () {
  for i in {1..5}
  do
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN" ]
    then
      break;
    fi
    log_progress "Waiting for wifi interface to come back up"
    sleep 5
  done

  [ -n "$WLAN" ] && return 0

  log_progress "Couldn't determine wifi client device"
  nmcli c show
  return 1
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  if ! iw dev ap0 info &> /dev/null
  then
    # create additional virtual interface for the wifi device
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  # turn off power savings for both interfaces since they use
  # the same underlying hardware, and we don't want one to go
  # into power save mode just because the other is idle
  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  # set up access point on the virtual interface using networkmanager
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  # don't set band and channel, because that is controlled by the $WLAN interface
  #nmcli con modify TESLAUSB_AP 802-11-wireless.band bg
  #nmcli con modify TESLAUSB_AP 802-11-wireless.channel 6
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$WLAN" ]
then
  iw dev $WLAN interface add ap0 type __ap
  iw "$WLAN" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi

EOF
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
}


if systemctl --quiet is-enabled NetworkManager.service
then
  # force-install iw because otherwise it will get autoremoved when
  # alsa-utils is removed later
  apt-get -y --force-yes install iw || return 1
  if ! nm_add_ap
  then
    # Network Manager won't allow adding connections when started with a
    # read-only root fs, even if the root fs is not writeable, so try
    # again after restarting Network Manager
    log_progress "Retrying after restarting Network Manager"
    systemctl restart NetworkManager.service
    if ! nm_add_ap
    then
      log_progress "STOP: Failed to configure AP"
      exit 1
    fi
  fi
  log_progress "AP configured"
  exit 0
fi


if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]
then
  log_progress "No wpa_supplicant, skipping AP setup."
  exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf
then
  IP=${AP_IP:-"192.168.66.1"}
  NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')

  # install required packages
  log_progress "installing dnsmasq and hostapd"
  apt-get -y --force-yes install dnsmasq hostapd

  log_progress "configuring AP '$AP_SSID' with IP $IP"
  # create udev rule
  MAC="$(cat /sys/class/net/wlan0/address)"
  cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
	SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy0", \
	RUN+="/sbin/iw phy phy0 interface add ap0 type __ap", \
	RUN+="/bin/ip link set ap0 address $MAC"
	EOF

  # configure dnsmasq
  cat <<- EOF > /etc/dnsmasq.conf
	interface=lo,ap0
	no-dhcp-interface=lo,wlan0
	bind-interfaces
	bogus-priv
	dhcp-range=${NET}.10,${NET}.254,12h
	# don't configure a default route, we're not a router
	dhcp-option=3
	EOF

  # configure hostapd
  cat <<- EOF > /etc/hostapd/hostapd.conf
	ctrl_interface=/var/run/hostapd
	ctrl_interface_group=0
	interface=ap0
	driver=nl80211
	ssid=${AP_SSID}
	hw_mode=g
	channel=11
	wmm_enabled=0
	macaddr_acl=0
	auth_algs=1
	wpa=2
	wpa_passphrase=${AP_PASS}
	wpa_key_mgmt=WPA-PSK
	wpa_pairwise=TKIP CCMP
	rsn_pairwise=CCMP
	EOF
  cat <<- EOF > /etc/default/hostapd
	DAEMON_CONF="/etc/hostapd/hostapd.conf"
	EOF

  # define network interfaces. Note use of 'AP1' name, defined in wpa_supplication.conf below
  cat <<- EOF > /etc/network/interfaces
	source-directory /etc/network/interfaces.d

	auto lo
	auto ap0
	auto wlan0
	iface lo inet loopback

	allow-hotplug ap0
	iface ap0 inet static
	    address ${IP}
	    netmask 255.255.255.0
	    hostapd /etc/hostapd/hostapd.conf

	allow-hotplug wlan0
	iface wlan0 inet manual
	    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
	iface AP1 inet dhcp
	EOF

  # For bullseye it is apparently necessary to explicitly disable wpa_supplicant for the ap0 interface
  cat <<- EOF >> /etc/dhcpcd.conf
	# disable wpa_supplicant for the ap0 interface
	interface ap0
	nohook wpa_supplicant
	EOF

  if [ ! -L /var/lib/misc ]
  then
    if ! findmnt --mountpoint /mutable
    then
        mount /mutable
    fi
    mkdir -p /mutable/varlib
    mv /var/lib/misc /mutable/varlib
    ln -s /mutable/varlib/misc /var/lib/misc
  fi

  # update the host name to have the AP IP address, otherwise
  # clients connected to the IP will get 127.0.0.1 when looking
  # up the teslausb host name
  sed -i -e "/^127.0.0.1\s*localhost/b; s/^127.0.0.1\(\s*.*\)/$IP\1/" /etc/hosts

  # add ID string to wpa_supplicant
  sed -i -e 's/}/  id_str="AP1"\n}/'  /etc/wpa_supplicant/wpa_supplicant.conf
else
  log_progress "AP mode already configured"
fi
