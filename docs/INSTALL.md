# Manual Installation

Step-by-step instructions for installing Zenfan without the automated script.

## 1. Install binaries

```bash
sudo install -m 755 bin/zenbook-fan.sh          /usr/local/bin/zenbook-fan.sh
sudo install -m 755 bin/zenfan                  /usr/local/bin/zenfan
sudo install -m 755 bin/zenfan-night            /usr/local/bin/zenfan-night
sudo install -m 755 bin/zenfan-night-effective  /usr/local/bin/zenfan-night-effective
sudo install -m 755 bin/zenfan-write-conf       /usr/local/bin/zenfan-write-conf
sudo install -m 755 bin/zenfan-config-gui       /usr/local/bin/zenfan-config-gui
```

## 2. Install config

```bash
sudo install -m 644 config/zenfan.conf /etc/zenfan.conf
```

## 3. Install sudoers rule

```bash
sudo visudo -c -f config/zenfan-sudoers
sudo install -m 440 config/zenfan-sudoers /etc/sudoers.d/zenfan
```

## 4. Install polkit policy

```bash
sudo install -m 644 config/org.zenfan.policy /usr/share/polkit-1/actions/org.zenfan.policy
sudo systemctl reload polkit
pkaction --action-id org.zenfan.write-conf --verbose   # should show implicit active: yes
```

## 5. Install and start systemd service

```bash
sudo install -m 644 systemd/zenfan.service /lib/systemd/system/zenfan.service
sudo systemctl daemon-reload
sudo systemctl enable zenfan.service
sudo systemctl start zenfan.service
systemctl status zenfan
```

## 6. Install Cinnamon applet

```bash
APPLET_DIR="$HOME/.local/share/cinnamon/applets/zenfan@ux31e"
mkdir -p "$APPLET_DIR"
install -m 644 applet/applet.js            "$APPLET_DIR/applet.js"
install -m 644 applet/metadata.json        "$APPLET_DIR/metadata.json"
install -m 644 applet/settings-schema.json "$APPLET_DIR/settings-schema.json"
```

Then: Right-click panel → Applets → search **Zenfan** → Add to panel

## 7. Verify

```bash
systemctl status zenfan
zenfan quiet && zenfan balanced     # no password prompt
zenfan-night status
zenfan-night-effective
zenfan-config-gui
```
