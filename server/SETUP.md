# Server (Fedora on MacBookPro10,1)

Operating system setup of the server. The cluster itself is in [k3s/SETUP.md](../k3s/SETUP.md) (it also covers firewalld). Commands run on the server; files are copied from this directory first:

```bash
scp -r server myexe@192.168.1.3:~/
```

```bash
cd ~/server
```

## Hostname

k3s names the node after the hostname. Without a static hostname the name comes from DHCP and may not be there yet when k3s starts, so k3s registers a second node (`localhost.localdomain`). Set it permanently:

```bash
sudo hostnamectl set-hostname s1.home
```

If a stray node already appeared: `sudo systemctl restart k3s`, then `kubectl delete node <stray node>`.

## Time zone

```bash
sudo timedatectl set-timezone UTC
```

## CPU frequency limit

Limits the maximum frequency to 2500 MHz on all cores:

```bash
sudo cp cpu-limit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-limit.service
```

## Network watchdog

The Wi-Fi adapter (BCM4331, `wl` driver) sometimes stops passing traffic without NetworkManager noticing. Every minute the watchdog pings the router (3 packets) and resets the Wi-Fi radio if all are lost; actions are logged. The script goes to `/usr/local/sbin` (SELinux does not allow running it from `/etc/systemd/system`):

```bash
sudo install -m 755 network-watchdog.sh /usr/local/sbin/network-watchdog.sh
sudo install -m 644 network-watchdog.service network-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now network-watchdog.timer
```

Log (empty while the network is fine):

```bash
journalctl -t network-watchdog
```

## Wi-Fi driver

TODO: driver installation instructions (to be added).

## Discrete GPU

The discrete GPU shares a heatsink with the CPU and adds about 13 °C (66 °C against 53 °C at the same load). Switching to the integrated GPU turns it off, the screen stays black until reboot:

```bash
echo IGD | sudo tee /sys/kernel/debug/vgaswitcheroo/switch
```

Do not switch back with `ON`/`DIS`: the nouveau driver cannot resume the card, reboot instead (if the reboot hangs, hold the power button for 10 seconds).

## Tools

```bash
sudo dnf install lm_sensors sysstat s-tui
```

- `sensors`: temperatures and fan speed.
- `pidstat -u 30 1 | grep '^Average' | sort -k8 -nr | head`: CPU usage per process averaged over 30 seconds.
- `s-tui`: frequency, temperature and load graphs.
