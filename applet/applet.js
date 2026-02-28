const Applet    = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Util      = imports.misc.util;
const GLib      = imports.gi.GLib;
const Gio       = imports.gi.Gio;
const St        = imports.gi.St;
const Cairo     = imports.cairo;

// ─────────────────────────────────────────────────────────────────────────────
// Promisify once at module load — patches the prototype so every instance
// gets await-able versions of these GIO async methods.
// ─────────────────────────────────────────────────────────────────────────────

Gio._promisify(Gio.Subprocess.prototype, "communicate_utf8_async", "communicate_utf8_finish");
// Gio.File promisify removed — all file reads use GLib.file_get_contents (see readSysFile)

// ─────────────────────────────────────────────────────────────────────────────
// Absolute binary paths — Cinnamon's applet environment does not inherit the
// user's $PATH, so we never rely on name resolution.
// ─────────────────────────────────────────────────────────────────────────────

const BIN = {
    zenfan:            "/usr/local/bin/zenfan",
    zenfanNight:       "/usr/local/bin/zenfan-night",
    zenfanNightEff:    "/usr/local/bin/zenfan-night-effective",
    zenfanConfigGui:   "/usr/local/bin/zenfan-config-gui",
};

// sysfs paths — no subprocess needed, plain file reads
const SYS = {
    temp:      "/sys/class/hwmon/hwmon2/temp1_input",
    pwm:       "/sys/class/hwmon/hwmon4/pwm1",
    pwmEnable: "/sys/class/hwmon/hwmon4/pwm1_enable",
    rpm:       "/sys/class/hwmon/hwmon4/fan1_input",
};
const CONF = "/etc/zenfan.conf";

// ─────────────────────────────────────────────────────────────────────────────
// Async primitives
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Spawn an absolute-path binary and return trimmed stdout.
 * Uses a shell so sudo and env are handled correctly.
 * Throws on spawn failure; resolves even on non-zero exit
 * (callers decide what to do with unexpected output).
 *
 * @param {string[]} argv   Full argv, e.g. [BIN.zenfan, "status"]
 * @returns {Promise<string>}
 */
async function runAsync(argv) {
    const proc = new Gio.Subprocess({
        argv,
        flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE,
    });
    proc.init(null);
    const [stdout] = await proc.communicate_utf8_async(null, null);
    return (stdout ?? "").trim();
}

/**
 * Read a sysfs / config file without spawning any process.
 * @param {string} path
 * @returns {Promise<string>}
 */
function readSysFile(path) {
    // sysfs / procfs files are kernel virtual — reads are instantaneous,
    // so sync GLib.file_get_contents is perfectly safe and avoids any
    // Uint8Array / GBytes conversion ambiguity from the async API.
    try {
        const [ok, raw] = GLib.file_get_contents(path);
        if (!ok) return null;
        return imports.byteArray.toString(raw).trim();
    } catch { return null; }
}



// ─────────────────────────────────────────────────────────────────────────────
// Applet
// ─────────────────────────────────────────────────────────────────────────────

class ZenFanApplet extends Applet.TextApplet {

    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this.graphData = new Array(60).fill(50);
        this._lastRpm  = null;  // cache last known RPM for manual control mode

        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu        = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);

        this._scheduleCache    = null;
        this._scheduleLastRead = 0;

        // Prevents overlapping refresh cycles
        this._refreshPending = false;

        this.buildMenu();
        this.updateAll();
        this.startAutoRefresh();
    }

    // ── Menu ─────────────────────────────────────────────────────────────────

    buildMenu() {
        this.menu.removeAll();

        this.graphArea = new St.DrawingArea({
            height: 130, width: 260, x_expand: true, y_expand: true,
        });
        this.graphArea.connect("repaint", () => this._onRepaint());
        this.menu.addActor(this.graphArea, { expand: true });

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this.tempLabel    = new PopupMenu.PopupMenuItem("Temperature: -- °C", { reactive: false });
        this.rpmLabel     = new PopupMenu.PopupMenuItem("Fan speed: -- RPM",  { reactive: false });
        this.profileLabel = new PopupMenu.PopupMenuItem("Profile: --",         { reactive: false });
        this.menu.addMenuItem(this.tempLabel);
        this.menu.addMenuItem(this.rpmLabel);
        this.menu.addMenuItem(this.profileLabel);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._profileItems = [];
        this.addProfileItem("quiet");
        this.addProfileItem("balanced");
        this.addProfileItem("performance");

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.nightModeItem = new PopupMenu.PopupSubMenuMenuItem("Night acoustic mode");
        this.menu.addMenuItem(this.nightModeItem);
        this.addNightModeChoice("🌙 Force Night",     "on");
        this.addNightModeChoice("☀ Force Day",        "off");
        this.addNightModeChoice("🕒 Auto (schedule)", "auto");

        let configItem = new PopupMenu.PopupMenuItem("Configure night hours");
        configItem.connect("activate", () => {
            // Launch GUI as the current user (not root) so GTK and $DISPLAY work.
            // The script handles privilege escalation internally via pkexec.
            try {
                GLib.spawn_async(
                    null,                        // working dir (inherit)
                    [BIN.zenfanConfigGui],        // argv
                    null,                        // envp (inherit full environment)
                    GLib.SpawnFlags.DEFAULT,
                    null                         // child setup
                );
            } catch (e) {
                logError(e, "ZenFanApplet: failed to launch config GUI");
            }
        });
        this.menu.addMenuItem(configItem);
    }

    addProfileItem(profile) {
        let item = new PopupMenu.PopupMenuItem("Set " + profile);
        item.connect("activate", () => {
            // No sudo — zenfan uses pkexec internally (polkit action: org.zenfan.set-profile)
            Util.spawnCommandLine(BIN.zenfan + " " + profile);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, () => {
                this.updateAll();
                return GLib.SOURCE_REMOVE;
            });
        });
        this.menu.addMenuItem(item);
        this._profileItems.push(item);
    }

    addNightModeChoice(label, mode) {
        let item = new PopupMenu.PopupMenuItem(label);
        item.connect("activate", () => {
            // No sudo — zenfan-night writes to /tmp/zenfan-night-mode (world-writable)
            Util.spawnCommandLine(BIN.zenfanNight + " " + mode);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, () => {
                this.updateAll();
                return GLib.SOURCE_REMOVE;
            });
        });
        this.nightModeItem.menu.addMenuItem(item);
    }

    // ── Graph ─────────────────────────────────────────────────────────────────

    _onRepaint() {
        let cr = this.graphArea.get_context();
        let w  = this.graphArea.get_width();
        let h  = this.graphArea.get_height();
        if (w < 1 || h < 1) { cr.$dispose(); return; }

        const PAD_L = 34, PAD_B = 16, PAD_T = 8, PAD_R = 6;
        const gw = w - PAD_L - PAD_R;
        const gh = h - PAD_B - PAD_T;

        let maxT = Math.max(80, this.graphData.reduce((a, b) => Math.max(a, b), 0));
        let minT = Math.min(40, this.graphData.reduce((a, b) => Math.min(a, b), 100));
        let span = maxT - minT || 1;

        const tempToY = (t) => PAD_T + gh - ((t - minT) / span) * gh;
        const tempToColor = (t) => {
            if (t <= 50) return [0.10, 0.70, 0.95, 1.0];
            if (t <= 65) { let f = (t-50)/15; return [0.10+0.80*f, 0.70-0.26*f, 0.95-0.55*f, 1.0]; }
            if (t <= 80) { let f = (t-65)/15; return [0.90+0.10*f, 0.44-0.40*f, 0.40-0.38*f, 1.0]; }
            return [1.0, 0.04, 0.02, 1.0];
        };

        // Background
        cr.setSourceRGBA(0.08, 0.08, 0.12, 0.95);
        cr.rectangle(0, 0, w, h); cr.fill();

        // Grid lines
        cr.setLineWidth(1);
        cr.setSourceRGBA(0.28, 0.28, 0.35, 0.6);
        [0.25, 0.5, 0.75].forEach(frac => {
            let gy = PAD_T + gh * frac;
            cr.moveTo(PAD_L, gy); cr.lineTo(w - PAD_R, gy); cr.stroke();
        });

        // 75 °C threshold
        if (maxT >= 75 && minT <= 75) {
            let ty = tempToY(75);
            cr.setLineWidth(1);
            cr.setSourceRGBA(0.95, 0.40, 0.10, 0.55);
            cr.setDash([4, 4], 0);
            cr.moveTo(PAD_L, ty); cr.lineTo(w - PAD_R, ty); cr.stroke();
            cr.setDash([], 0);
            cr.setFontSize(9);
            cr.setSourceRGBA(0.95, 0.40, 0.10, 0.80);
            cr.moveTo(PAD_L + 2, ty - 2); cr.showText("75°");
        }

        // Gradient fill
        let curTemp = this.graphData[this.graphData.length - 1];
        let [cr1, cg1, cb1] = tempToColor(curTemp);
        let fillGrad = new Cairo.LinearGradient(0, PAD_T, 0, PAD_T + gh);
        fillGrad.addColorStopRGBA(0, cr1, cg1, cb1, 0.35);
        fillGrad.addColorStopRGBA(1, cr1, cg1, cb1, 0.03);
        cr.setSource(fillGrad);
        let n = this.graphData.length;
        for (let i = 0; i < n; i++) {
            let x = PAD_L + i * gw / (n - 1);
            let y = tempToY(this.graphData[i]);
            if (i === 0) cr.moveTo(x, y); else cr.lineTo(x, y);
        }
        cr.lineTo(PAD_L + gw, PAD_T + gh);
        cr.lineTo(PAD_L,      PAD_T + gh);
        cr.closePath(); cr.fill();

        // Coloured line segments
        cr.setLineWidth(2);
        for (let i = 1; i < n; i++) {
            let [r0,g0,b0] = tempToColor(this.graphData[i-1]);
            let [r1,g1,b1] = tempToColor(this.graphData[i]);
            cr.setSourceRGBA((r0+r1)/2, (g0+g1)/2, (b0+b1)/2, 1.0);
            cr.moveTo(PAD_L + (i-1) * gw / (n-1), tempToY(this.graphData[i-1]));
            cr.lineTo(PAD_L +  i    * gw / (n-1), tempToY(this.graphData[i]));
            cr.stroke();
        }

        // Live dot + glow
        {
            let x = PAD_L + gw;
            let y = tempToY(curTemp);
            let [dr, dg, db] = tempToColor(curTemp);
            cr.setSourceRGBA(dr, dg, db, 0.25); cr.arc(x, y, 6, 0, 2*Math.PI); cr.fill();
            cr.setSourceRGBA(dr, dg, db, 1.00); cr.arc(x, y, 3, 0, 2*Math.PI); cr.fill();
        }

        // Axes
        cr.setLineWidth(1.5);
        cr.setSourceRGBA(0.45, 0.45, 0.55, 0.9);
        cr.moveTo(PAD_L, PAD_T); cr.lineTo(PAD_L, PAD_T + gh);
        cr.lineTo(w - PAD_R, PAD_T + gh); cr.stroke();

        // Y labels
        cr.setFontSize(10);
        cr.setSourceRGBA(0.65, 0.65, 0.72, 1.0);
        cr.moveTo(2, PAD_T + 10);         cr.showText(Math.round(maxT) + "°");
        cr.moveTo(2, PAD_T + gh);         cr.showText(Math.round(minT) + "°");
        cr.moveTo(2, PAD_T + gh * 0.5 + 4); cr.showText(Math.round((maxT+minT)/2) + "°");

        cr.$dispose();
    }

    // ── Async readers ─────────────────────────────────────────────────────────

    async _readTemp() {
        try {
            let raw = readSysFile(SYS.temp);
            let val = parseInt(raw);
            return isNaN(val) ? null : val / 1000;
        } catch { return null; }
    }

    async _readPwm() {
        try {
            let raw = readSysFile(SYS.pwm);
            let val = parseInt(raw);
            return isNaN(val) ? null : val;
        } catch { return null; }
    }

    async _readRpm() {
        try {
            let raw = readSysFile(SYS.rpm);
            let val = parseInt(raw);
            if (isNaN(val) || val === 0) return null;  // 0 = manual control mode, tachometer stopped
            this._lastRpm = val;  // cache last known good reading
            return val;
        } catch { return null; }
    }

    // Returns true if daemon is in manual control (pwm1_enable = 1 = daemon active)
    // Returns false if auto mode (pwm1_enable = 2 = daemon inactive / BIOS control)
    _readDaemonActive() {
        try {
            let raw = readSysFile(SYS.pwmEnable);
            return parseInt(raw) === 1;
        } catch { return false; }
    }

    async _readProfile() {
        try {
            let out = await runAsync([BIN.zenfan, "status"]);
            // e.g. "Current profile: balanced"
            return out.replace("Current profile:", "").trim() || "?";
        } catch { return "?"; }
    }

    async _readSchedule() {
        let now = Date.now();
        if (this._scheduleCache && now - this._scheduleLastRead < 10000)
            return this._scheduleCache;

        try {
            let text  = readSysFile(CONF);
            let start = 22, end = 7;
            for (let line of text.split("\n")) {
                if (line.startsWith("NIGHT_START=")) start = parseInt(line.split("=")[1]);
                if (line.startsWith("NIGHT_END="))   end   = parseInt(line.split("=")[1]);
            }
            this._scheduleCache    = this.formatHour(start) + " → " + this.formatHour(end);
            this._scheduleLastRead = now;
        } catch {
            this._scheduleCache = "22:00 → 07:00";
        }
        return this._scheduleCache;
    }

    async _readNightMode() {
        try {
            let mode = await runAsync([BIN.zenfanNight, "status"]);
            // Returns "on", "off", or "auto"
            if (mode === "on" || mode === "off") return mode;
            // "auto" — resolve which branch is active right now
            let effective = await runAsync([BIN.zenfanNightEff]);
            return effective || "unknown";   // "auto-on" or "auto-off"
        } catch { return "unknown"; }
    }

    // ── Refresh orchestration ─────────────────────────────────────────────────

    async updateAll() {
        if (this._refreshPending) return;
        this._refreshPending = true;

        try {
            // All five reads run concurrently — nothing blocks the main thread
            let [temp, pwm, rpm, profile, nightState, schedule] = await Promise.all([
                this._readTemp(),
                this._readPwm(),
                this._readRpm(),
                this._readProfile(),
                this._readNightMode(),
                this._readSchedule(),
            ]);

            // Daemon active = pwm1_enable is 1 (manual control)
            // Daemon inactive = pwm1_enable is 2 (BIOS auto)
            let daemonActive = this._readDaemonActive();

            this._applyToUI(temp, pwm, rpm, profile, nightState, schedule, daemonActive);

        } catch (e) {
            logError(e, "ZenFanApplet.updateAll");
        } finally {
            this._refreshPending = false;
        }
    }

    // ── UI update ─────────────────────────────────────────────────────────────

    _applyToUI(temp, pwm, rpm, profile, nightState, schedule, daemonActive) {
        // ── Daemon state ──────────────────────────────────────────────────────
        // When daemon is inactive (pwm1_enable=2), fan is under BIOS auto control.
        // Disable profile/night controls and show BIOS Auto state.

        // Enable/disable profile items
        this._profileItems.forEach(item => item.setSensitive(daemonActive));
        this.nightModeItem.setSensitive(daemonActive);

        // ── RPM / percent ─────────────────────────────────────────────────────
        let percent, rpmVal;

        if (!daemonActive) {
            // BIOS auto mode — daemon not running
            percent = "0";
            // Still show live RPM from tachometer if available
            if (rpm !== null && rpm <= 15000) {
                rpmVal = rpm;
                this._lastRpm = rpm;
            } else if (this._lastRpm !== null) {
                rpmVal = this._lastRpm + "~";
            } else {
                rpmVal = "N/A";
            }
        } else {
            // Daemon active (manual control mode — tachometer stopped)
            percent = (pwm !== null) ? Math.round((pwm / 255) * 100) : "?";
            if (rpm !== null && rpm <= 15000) {
                // Tachometer reading available (transitional / just switched)
                rpmVal = rpm;
                this._lastRpm = rpm;
            } else if (pwm !== null) {
                // Estimate from PWM: linear 0–255 → 0–6200, round to nearest 100
                let estimated = Math.round(((pwm / 255) * 6200) / 100) * 100;
                rpmVal = estimated + "~";
            } else if (this._lastRpm !== null) {
                rpmVal = this._lastRpm + "~";
            } else {
                rpmVal = "?";
            }
        }

        // ── Labels ────────────────────────────────────────────────────────────
        if (temp !== null) {
            this.graphData.push(temp);
            this.graphData.shift();
            this.graphArea.queue_repaint();
            this.tempLabel.label.text = "Temperature: " + Math.round(temp) + " °C";
            this.updatePanelDisplay(temp, nightState, daemonActive);
        }

        this.rpmLabel.label.text = daemonActive
            ? "Fan speed: " + rpmVal + " RPM (" + percent + "%)"
            : "Fan speed: " + rpmVal + " RPM";

        this.profileLabel.label.text = daemonActive
            ? "Profile: " + profile
            : "Profile: BIOS Auto";

        let nightLabel = this.nightStateToLabel(nightState);
        if (daemonActive) {
            this.set_applet_tooltip(
                "Profile: "      + profile +
                "\nFan speed: "  + rpmVal + " RPM (" + percent + "%)" +
                "\nNight mode: " + nightLabel +
                "\nQuiet hours: " + schedule
            );
        } else {
            this.set_applet_tooltip(
                "⚙ Fan control: BIOS Auto (daemon inactive)" +
                "\nFan speed: "  + rpmVal + " RPM" +
                "\nProfile controls disabled"
            );
        }

        this.updateNightMenuState(nightState, schedule, daemonActive);
    }

    // ── Display helpers ───────────────────────────────────────────────────────

    updatePanelDisplay(temp, nightState, daemonActive) {
        let color = "#157510", icon = "❄";
        if      (temp >= 75) { color = "#a92828"; icon = "🔥"; }
        else if (temp >= 65) { color = "#f57900"; icon = "🌡"; }
        else if (temp >= 55) { color = "#885c14"; }

        let moon   = (nightState === "on" || nightState === "auto-on") ? " 🌙" : "";
        let bios   = daemonActive ? "" : " ⚙";   // gear = BIOS auto
        this.set_applet_label(`${icon} ${Math.round(temp)}°${moon}${bios}`);
        if (this._applet_label)
            this._applet_label.set_style(`color: ${color}; font-weight: bold;`);
    }

    updateNightMenuState(state, schedule, daemonActive) {
        if (!this.nightModeItem) return;
        if (!daemonActive) {
            this.nightModeItem.label.text = "Night acoustic mode: ⚙ BIOS Auto";
            return;
        }
        this.nightModeItem.label.text =
            "Night acoustic mode: " + this.nightStateToLabel(state) +
            "  (" + schedule + ")";
    }

    nightStateToLabel(state) {
        if (state === "on")       return "🌙 Forced";
        if (state === "off")      return "☀ Disabled";
        if (state === "auto-on")  return "🕒 Auto (quiet active)";
        if (state === "auto-off") return "🕒 Auto (daytime)";
        return "?";
    }

    formatHour(h) {
        let n = parseInt(h);
        return isNaN(n) ? "??:00" : (n < 10 ? "0" : "") + n + ":00";
    }

    // ── Auto-refresh ──────────────────────────────────────────────────────────

    startAutoRefresh() {
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            this.updateAll();          // async — returned Promise intentionally ignored
            return GLib.SOURCE_CONTINUE;
        });
    }

    on_applet_clicked() { this.menu.toggle(); }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new ZenFanApplet(metadata, orientation, panelHeight, instanceId);
}
