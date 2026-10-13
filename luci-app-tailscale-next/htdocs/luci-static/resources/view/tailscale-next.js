'use strict';
'require view';
'require fs';
'require poll';
'require rpc';
'require ui';
'require uci';

var UPDATE_BIN = '/usr/libexec/tailscale-next-update';
var TS_BIN = '/usr/sbin/tailscale';
var INITD = '/etc/init.d/tailscale-next';
var LOG_FILE = '/tmp/tailscale-next-update.log';
var RC_FILE = '/tmp/tailscale-next-update.rc';
var STATUS_FILE = '/tmp/tailscale-next-update.status';
var BACKUP_DIR = '/etc/tailscale/.update-backup';
var LOGIN_TRIGGER_FILE = '/tmp/tailscale-next-login.request';

// commit just this config: immediate and reliable, unlike uci apply's
// rollback machinery with its deferred replies
var callUciCommit = rpc.declare({
    object: 'uci',
    method: 'commit',
    params: ['config']
});

return view.extend({
    load: function () {
        return uci.load('tailscale-next').then(function () {
            return uci.load('network');
        });
    },

    // tailscale status

    fetchStatus: function () {
        return fs.exec(TS_BIN, ['status', '--json']).then(function (res) {
            if (res.code !== 0)
                return { error: (res.stderr || res.stdout || '').trim() };
            try {
                return JSON.parse(res.stdout || '{}');
            } catch (e) {
                return { error: (res.stdout || '').slice(0, 200) };
            }
        }).catch(function (e) {
            return { error: e.message || String(e) };
        });
    },

    // a real button: <a href="#"> shows a local # URL and invites
    // middle-click, both nonsense for JS-only actions
    link: function (text, style, onclick) {
        var attrs = { 'class': 'btn cbi-button' };
        if (style) attrs['style'] = style;
        attrs['click'] = function (ev) {
            ev.preventDefault();
            if (onclick) onclick(ev);
        };
        return E('button', attrs, [text]);
    },

    renderStatus: function (ts) {
        if (!this.dynEl) return;
        var node = this.dynEl;
        node.innerHTML = '';

        if (!ts || ts.error || !ts.BackendState) {
            // CLI unreachable: expected while disabled or briefly during
            // (re)starts - show "Starting" only in that window
            var warming = this.cfg['enabled'] === '1' && (Date.now() - this.startedAt) < 30000;
            node.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, [_('Status')]),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('span', { 'style': warming ? 'color:#b8860b' : 'color:red' },
                        [warming ? _('Starting...') : _('Not running')])
                ])
            ]));
            return;
        }

        // only Running is green; the other backend states need user action
        var labels = {
            Running: _('Running'),
            NeedsLogin: _('Needs login'),
            NeedsMachineAuth: _('Needs machine auth'),
            Starting: _('Starting...'),
            Stopped: _('Stopped')
        };
        node.appendChild(E('div', { 'class': 'cbi-value' }, [
            E('label', { 'class': 'cbi-value-title' }, [_('Status')]),
            E('div', { 'class': 'cbi-value-field' }, [
                E('span', { 'style': ts.BackendState === 'Running' ? 'color:green' : 'color:#b8860b' },
                    [labels[ts.BackendState] || ts.BackendState])
            ])
        ]));

        if (ts.Self && ts.Self.ID) {
            var idTxt = ts.Self.ID + (ts.Self.HostName ? ' (' + ts.Self.HostName + ')' : '');
            node.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, [_('Node')]),
                E('div', { 'class': 'cbi-value-field' }, [idTxt])
            ]));
        }

        if (ts.BackendState === 'NeedsLogin' && !ts.AuthURL) {
            // no AuthURL = no flow pending; drop the trigger and restart:
            // the new up instance renders a fresh URL
            var self = this;
            node.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, [_('Login')]),
                E('div', { 'class': 'cbi-value-field' }, [
                    this.link(_('Start login'), 'color:green', function () {
                        self.startedAt = Date.now();
                        fs.write(LOGIN_TRIGGER_FILE, '1').then(function () {
                            return fs.exec(INITD, ['restart']);
                        }).catch(function () {
                            return fs.exec(INITD, ['restart']);
                        });
                    })
                ])
            ]));
        }

        if (ts.AuthURL) {
            node.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, [_('Authenticate')]),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('a', { 'href': ts.AuthURL, 'target': '_blank' }, [ts.AuthURL])
                ])
            ]));
        }

        var user = ts.Self && ts.User && ts.Self.UserID != null ? ts.User[ts.Self.UserID] : null;
        var userName = user ? (user.DisplayName || user.LoginName) : null;
        // logout must not depend on resolving the account name (Headscale
        // status JSON has no User object at all)
        if (ts.Self && ts.Self.ID) {
            var self = this;
            var field = [];
            if (userName) {
                field.push(E('a', {
                    'href': 'https://login.tailscale.com/admin/machines/',
                    'target': '_blank'
                }, [userName]), E('br'));
            }
            field.push(this.link(_('Log out and unbind'), 'color:green', function () {
                if (!confirm(_('Log out and unbind the current device?'))) return;
                fs.exec(TS_BIN, ['logout']).finally(function () {
                    location.reload();
                });
            }));
            node.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, [_('Bound user')]),
                E('div', { 'class': 'cbi-value-field' }, field)
            ]));
        }
    },

    startStatusPoll: function () {
        var self = this;
        this._statusTick = function () {
            // SPA: poll callbacks outlive the DOM. Skip the spawn-heavy
            // probe (UPX self-extract) while the page/tab is hidden
            if (!self.dynEl || !self.dynEl.isConnected || document.hidden)
                return;
            return self.fetchStatus().then(function (ts) {
                self.renderStatus(ts);
                // (re)starts take seconds: poll fast until the daemon
                // answers, then settle to the cheap interval
                self.setPollInterval(ts && ts.BackendState ? 30 : 3);
            });
        };
        this._pollSec = null;
        this.setPollInterval(3);
        poll.start();
    },

    setPollInterval: function (sec) {
        if (this._pollSec === sec)
            return;
        this._pollSec = sec;
        // re-register outside the tick: mid-iteration mutation could
        // run the same callback twice
        var self = this;
        window.setTimeout(function () {
            poll.remove(self._statusTick);
            poll.add(self._statusTick, sec);
            poll.start();
        }, 0);
    },

    // config widgets

    cbiRow: function (title, input, descr, forId) {
        var field = [input];
        if (descr) field.push(E('div', { 'class': 'cbi-value-description' }, [descr]));
        return E('div', { 'class': 'cbi-value' }, [
            E('label', { 'class': 'cbi-value-title', 'for': forId || null }, [title]),
            E('div', { 'class': 'cbi-value-field' }, field)
        ]);
    },

    checkBox: function (key, title, descr, onchange) {
        var self = this;
        var id = 'tsn-' + key;
        return this.cbiRow(title, E('div', { 'class': 'cbi-checkbox' }, [
            E('input', {
                'id': id,
                'type': 'checkbox',
                'name': key,
                'checked': self.cfg[key] === '1' || null,
                'change': function (ev) {
                    self.cfg[key] = ev.target.checked ? '1' : '0';
                    self.dirty[key] = true;
                    if (onchange) onchange(ev.target.checked);
                }
            }),
            E('label', { 'for': id })
        ]), descr, id);
    },

    // keepBackups select (0-3, stored in UCI like the other settings)
    backupSelect: function () {
        var self = this;
        var id = 'tsn-keepBackups';
        var opts = [];
        for (var i = 0; i <= 3; i++) {
            opts.push(E('option', {
                'value': String(i),
                'selected': (self.cfg['keepBackups'] || '3') === String(i) || null
            }, [String(i)]));
        }
        return this.cbiRow(_('Backups to keep'), E('select', {
            'id': id,
            'class': 'cbi-input-select',
            'name': 'keepBackups',
            'change': function (ev) {
                self.cfg['keepBackups'] = ev.target.value;
                self.dirty['keepBackups'] = true;
            }
        }, opts), _('Number of update backups kept on this device (0 disables backups).'), id);
    },

    // LAN subnet from uci network config: prefix inside ipaddr
    // (192.168.1.1/24) or a separate netmask option; null if undeterminable
    lanSubnet: function () {
        var ipaddr = uci.get('network', 'lan', 'ipaddr');
        var netmask = uci.get('network', 'lan', 'netmask');
        if (Array.isArray(ipaddr)) ipaddr = ipaddr[0];
        if (Array.isArray(netmask)) netmask = netmask[0];
        if (typeof ipaddr !== 'string' || ipaddr.indexOf(':') !== -1)
            return null;
        var parts = ipaddr.split('/');
        var ip = parts[0].split('.').map(function (x) { return +x; });
        var bits, i;
        if (parts.length === 2) {
            bits = +parts[1];
        } else {
            if (typeof netmask !== 'string')
                return null;
            var mask = netmask.split('.').map(function (x) { return +x; });
            if (mask.length !== 4 || mask.some(isNaN))
                return null;
            bits = 0;
            for (i = 0; i < 4; i++)
                bits += ((mask[i] & 0xff).toString(2)).replace(/0/g, '').length;
        }
        if (ip.length !== 4 || ip.some(isNaN) || !(bits >= 8 && bits <= 30))
            return null;
        var mbits = function (n) {
            var v = bits - n * 8;
            return v >= 8 ? 255 : v > 0 ? (256 - (1 << (8 - v))) & 255 : 0;
        };
        return ip.map(function (b, n) { return b & mbits(n); }).join('.') + '/' + bits;
    },

    textInput: function (key, title, opts) {
        opts = opts || {};
        var self = this;
        var id = 'tsn-' + key;
        return this.cbiRow(title, E('div', {}, [
            E('input', {
                'id': id,
                'type': opts.password ? 'password' : 'text',
                'class': opts.password ? 'cbi-input-password' : 'cbi-input-text',
                'name': key,
                'value': self.cfg[key] || '',
                'placeholder': opts.placeholder || '',
                'change': function (ev) {
                    self.cfg[key] = ev.target.value.trim();
                    self.dirty[key] = true;
                }
            })
        ]), opts.descr, id);
    },

    // the footer auto-renders Save & Apply / Reset once handleSave exists;
    // route both to our flow. Reset = no-op.
    handleSaveApply: function (ev) {
        return this.handleSave(ev);
    },

    handleReset: function () {
        return Promise.resolve();
    },

    handleSave: function (ev) {
        ev.preventDefault();
        var self = this;
        if (!self.sid) {
            ui.addNotification(null, _('tailscale-next config section not found'), 'error');
            return;
        }
        // light validation: the one-shot applier's failures surface
        // nowhere, so reject bogus input here
        var routes = (self.cfg['advertiseRoutes'] || '').trim();
        if (routes && !/^[0-9a-fA-F:.,\/ ]+$/.test(routes)) {
            ui.addNotification(null, _('Advertise routes must be a comma-separated list of IP subnets (e.g. 10.0.0.0/24)'), 'error');
            return;
        }
        var server = (self.cfg['loginServer'] || '').trim();
        if (server && !/^https?:\/\/\S+$/i.test(server)) {
            ui.addNotification(null, _('Server URL must start with http:// or https://'), 'error');
            return;
        }
        // a disabled service never runs `tailscale up`: don't let a stale
        // invalid exit node block disabling
        var en = (self.cfg['exitNode'] || '').trim();
        if (self.cfg['enabled'] === '1' && en && !/^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F:]+|[A-Za-z0-9][A-Za-z0-9._-]*)$/.test(en)) {
            ui.addNotification(null, _('Exit node must be a Tailscale IP or node name, not a subnet (e.g. 100.64.0.1 or my-exit-node)'), 'error');
            return;
        }
        var keys = ['enabled', 'acceptRoutes', 'advertiseRoutes', 'hostname',
            'loginServer', 'authkey', 'checkOnLoad', 'keepBackups', 'autoUpdate',
            'advertiseExitNode', 'exitNode', 'exitNodeAllowLan'];
        keys.forEach(function (k) {
            if (self.dirty[k])
                uci.set('tailscale-next', self.sid, k, self.cfg[k]);
        });
        var touched = Object.keys(self.dirty).length > 0;
        uci.save().then(function () {
            // deltas are per-session: skip the commit on no-op saves, like
            // the stock checkChange() guard
            return uci.changes().then(function (deltas) {
                if (!deltas || !deltas['tailscale-next'] || !deltas['tailscale-next'].length) {
                    // no staged deltas: repeated no-op save, or an external
                    // commit landed ours - restart anyway in the latter case
                    if (touched)
                        fs.exec(INITD, ['restart']);
                    return;
                }
                // restart without awaiting: rpcd keeps it running after we
                // navigate away; awaiting would freeze the page 5-15s
                return callUciCommit('tailscale-next').then(function () {
                    fs.exec(INITD, ['restart']);
                });
            });
        }).then(function () {
            location.reload();
        }).catch(function (e) {
            ui.addNotification(null, _('Save failed: %s').format(e.message || String(e)), 'error');
        });
    },

    // updater panel

    // update check with a client-side timeout guard; on page load only
    // when the preference is set, or via the button
    checkUpdate: function () {
        var self = this;
        var done = false;
        var real = fs.exec(UPDATE_BIN, ['--check', '--json']).then(function (res) {
            done = true;
            var out = (res.stdout || '').trim();
            var st;
            if (!out)
                st = { error: (res.stderr || '').trim() || _('no output') };
            else {
                try { st = JSON.parse(out); }
                catch (e) { st = { error: out }; }
            }
            self.updateState = st;
            self.refreshUpdateView();
            return st;
        });
        var slow = new Promise(function (resolve) {
            window.setTimeout(function () {
                if (!done)
                    resolve({ error: _('Check timed out, please try again') });
            }, 10000);
        });
        return Promise.race([real, slow]).then(function (st) {
            self.updateState = st;
            self.refreshUpdateView();
            return st;
        });
    },

    callUpdater: function (args) {
        return fs.exec(UPDATE_BIN, args);
    },

    readLog: function () {
        return fs.read(LOG_FILE).catch(function () { return ''; });
    },

    readRc: function () {
        return fs.read(RC_FILE).catch(function () { return ''; });
    },

    readStatus: function () {
        return fs.read(STATUS_FILE).catch(function () { return ''; });
    },

    setLog: function (text) {
        if (this.logEl) {
            this.logEl.textContent = text || '';
            this.logEl.scrollTop = this.logEl.scrollHeight;
        }
    },

    notice: function (title, msg, type, seconds) {
        var body = E('p', {}, [msg]);
        var n = ui.addNotification(title, body, type);
        if (!seconds || seconds <= 0)
            return n;
        var remaining = seconds;
        body.textContent = msg + ' (' + remaining + ')';
        var timer = setInterval(function () {
            remaining--;
            if (remaining <= 0) {
                clearInterval(timer);
                try {
                    if (n && typeof n.remove === 'function')
                        n.remove();
                    else if (n && n.parentNode)
                        n.parentNode.removeChild(n);
                } catch (e) { }
                return;
            }
            body.textContent = msg + ' (' + remaining + ')';
        }, 1000);
        return n;
    },

    handleCheck: function (ev) {
        if (ev) ev.preventDefault();
        return this.checkUpdate();
    },

    handleUpdate: function (ev) {
        if (ev) ev.preventDefault();
        var self = this;
        self.startErr = '';
        return fs.remove(RC_FILE).catch(function () { }).then(function () {
            return self.callUpdater(['--start']);
        }).catch(function (e) {
            // file exec replies when the command pipe closes; a client-side
            // timeout often means the job detached cleanly - logged, not shown
            self.startErr = (e && (e.message || String(e))) || 'unknown';
            return null;
        }).then(function () {
            self.notice(null, _('Update started, reading progress...'), 'info', 10);
            self.startPolling();
        });
    },

    handleRollback: function (ev) {
        if (ev) ev.preventDefault();
        var self = this;
        if (!confirm(_('Roll back to the last backed-up Tailscale version?')))
            return Promise.resolve();
        return fs.list(BACKUP_DIR).then(function (entries) {
            if (!entries || !entries.length) {
                ui.addNotification(null, _('No backup available on this device.'), 'error');
                return null;
            }
            return self.callUpdater(['--rollback']).then(function (res) {
                self.notice(null, (res.stdout || res.stderr || '').trim(), 'info', 10);
                return self.handleCheck(new Event('click'));
            });
        }).catch(function () {
            ui.addNotification(null, _('No backup available on this device.'), 'error');
        });
    },

    startPolling: function () {
        var self = this;
        var ticks = 0;
        if (this.polling)
            return;
        this.polling = true;
        this._pollTick = function () {
            ticks++;
            return Promise.all([self.readRc(), self.readLog()]).then(function (r) {
                var rc = (r[0] || '').trim();
                var log = (r[1] || '');
                if (!log && ticks === 5)
                    log = _('No log output yet. Start response: %s').format(self.startErr || _('ok'));
                self.setLog(log || _('(waiting for log...)'));
                if (rc !== '') {
                    self.stopUpdatePoll();
                    var msg, type, secs;
                    if (rc === '0') {
                        msg = _('Tailscale update completed.');
                        type = 'info';
                        secs = 10;
                    } else if (rc === '3') {
                        msg = _('Update skipped: another update is already running.');
                        type = 'info';
                        secs = 10;
                    } else {
                        msg = _('Update failed, see the log below.');
                        type = 'error';
                        secs = 0;
                    }
                    self.notice(null, msg, type, secs);
                    self.handleCheck(new Event('click'));
                } else if (ticks > 600) {  // ~30 min at 3s
                    self.stopUpdatePoll();
                    self.notice(null, _('The update seems stuck, see the log below.'), 'warning', 0);
                }
            });
        };
        poll.add(this._pollTick, 3);
        poll.start();
    },

    stopUpdatePoll: function () {
        this.polling = false;
        // poll.stop() is global: remove just this updater tick, keep the
        // status poll registered
        poll.remove(this._pollTick);
        this._pollTick = null;
        poll.start();
    },

    row: function (label, value) {
        return E('tr', { 'class': 'tr' }, [
            E('td', { 'class': 'td left', 'width': '33%' }, [label]),
            E('td', { 'class': 'td left' }, [value])
        ]);
    },

    // RAM from /proc/meminfo, space from busybox df (ACL allow-listed);
    // thresholds mirror the README table
    checkRequirements: function () {
        return Promise.all([
            fs.read('/proc/meminfo').catch(function () { return ''; }),
            fs.exec('/bin/df', ['-k', '/', '/tmp']).catch(function () { return null; })
        ]).then(function (r) {
            var out = { mem: { total: 0, avail: 0 }, df: { root: 0, tmp: 0 } };
            (r[0] || '').split('\n').forEach(function (line) {
                var m = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
                if (m)
                    out.mem[m[1] === 'MemTotal' ? 'total' : 'avail'] = parseInt(m[2], 10);
            });
            if (r[1] && r[1].stdout) {
                r[1].stdout.split('\n').forEach(function (line) {
                    var p = line.trim().split(/\s+/);
                    if (p.length >= 6 && (p[5] === '/' || p[5] === '/tmp'))
                        out.df[p[5] === '/' ? 'root' : 'tmp'] = parseInt(p[3], 10) || 0;
                });
            }
            return out;
        });
    },

    renderRequirements: function (req) {
        if (!this.reqEl)
            return;
        var node = this.reqEl;
        node.innerHTML = '';
        var mb = function (kb) { return kb ? Math.round(kb / 1024) + ' MB' : '-'; };
        var ver = function (v, okKb, lowKb) {
            if (!v)
                return E('span', { 'style': 'color:#888' }, ['-']);
            if (v < lowKb)
                return E('span', { 'style': 'color:red' }, [_('Too low')]);
            if (v < okKb)
                return E('span', { 'style': 'color:#b8860b' }, [_('Low')]);
            return E('span', { 'style': 'color:#080' }, [_('ok')]);
        };
        var mt = req.mem.total, ma = req.mem.avail;
        node.appendChild(E('table', { 'class': 'table' }, [
            this.row(_('Memory'), E('span', {}, [mb(mt) + ' (' + mb(ma) + ' ' + _('free') + ') ', ver(mt, 262144, 131072)])),
            this.row(_('Storage (/)'), E('span', {}, [mb(req.df.root) + ' ', ver(req.df.root, 37888, 10240)])),
            this.row(_('Storage (/tmp)'), E('span', {}, [mb(req.df.tmp) + ' ', ver(req.df.tmp, 30720, 30720)]))
        ]));
    },

    refreshUpdateView: function () {
        var st = this.updateState || {};
        var node = this.updateStateEl || document.getElementById('tsn-updater-state');
        if (!node)
            return;
        if (st.error) {
            node.innerHTML = '';
            node.appendChild(E('div', { 'class': 'alert-message warning' },
                [_('Failed to read status: %s').format(st.error)]));
            return;
        }
        var avail = st.update_available === true;
        node.innerHTML = '';
        node.appendChild(E('table', { 'class': 'table' }, [
            this.row(_('Installed version'), st.installed || _('not installed')),
            this.row(_('Latest version'), st.latest || '?'),
            this.row(_('Architecture'), (st.arch || '?') + ' (' + (st.kernel || '?') + ')'),
            this.row(_('State'), avail
                ? E('span', { 'style': 'color:#c00;font-weight:bold' }, [_('Update available')])
                : E('span', { 'style': 'color:#080' }, [_('Up to date')]))
        ]));
    },

    // render

    render: function () {
        var sect = (uci.sections('tailscale-next', 'settings') || [])[0];
        this.sid = sect ? sect['.name'] : null;
        this.cfg = {
            enabled: uci.get('tailscale-next', this.sid, 'enabled') || '0',
            acceptRoutes: uci.get('tailscale-next', this.sid, 'acceptRoutes') || '0',
            advertiseRoutes: uci.get('tailscale-next', this.sid, 'advertiseRoutes') || '',
            hostname: uci.get('tailscale-next', this.sid, 'hostname') || '',
            loginServer: uci.get('tailscale-next', this.sid, 'loginServer') || '',
            authkey: uci.get('tailscale-next', this.sid, 'authkey') || '',
            advertiseExitNode: uci.get('tailscale-next', this.sid, 'advertiseExitNode') || '0',
            exitNode: uci.get('tailscale-next', this.sid, 'exitNode') || '',
            exitNodeAllowLan: uci.get('tailscale-next', this.sid, 'exitNodeAllowLan') || '0',
            checkOnLoad: uci.get('tailscale-next', this.sid, 'checkOnLoad') || '0',
            keepBackups: uci.get('tailscale-next', this.sid, 'keepBackups') || '3',
            autoUpdate: uci.get('tailscale-next', this.sid, 'autoUpdate') || '0'
        };

        // page-load auto check only when the preference is set (default
        // off, like attendedsysupgrade); else the panel waits for the button
        this.updateState = null;
        this.autocheck = this.cfg['checkOnLoad'] === '1';
        // dirty-key tracking: only touched keys are written, so a stale
        // tab cannot clobber values changed elsewhere
        this.dirty = {};
        // reference for the transient "Starting..." state after (re)starts
        this.startedAt = Date.now();

        this.dynEl = E('div', {}, [E('div', { 'class': 'cbi-value' }, [
            E('label', { 'class': 'cbi-value-title' }, [_('Status')]),
            E('div', { 'class': 'cbi-value-field' }, [_('Loading status...')])
        ])]);
        this.statusEl = E('div', { 'class': 'cbi-section-node' }, [
            this.checkBox('enabled', _('Enable'), null, function (on) {
                var s = document.getElementById('tsn-settings');
                var h = document.getElementById('tsn-settings-hint');
                if (s) s.style.display = on ? '' : 'none';
                if (h) h.style.display = on ? 'none' : '';
            }),
            this.dynEl
        ]);

        this.updateStateEl = E('div', { 'id': 'tsn-updater-state', 'class': 'cbi-section' }, [
            this.autocheck ? _('Checking for updates...') : _('Enable "Check for updates" above to check automatically.')
        ]);
        this.reqEl = E('div');
        this.logEl = E('pre', {
            'style': 'max-height:22em;overflow:auto;white-space:pre-wrap;background:#111;color:#ddd;padding:8px;border-radius:4px;font-size:12px;'
        }, [_('(waiting for log...)')]);

        var self = this;
        var page = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, [_('Tailscale')]),
            E('div', { 'class': 'cbi-map-descr' }, [
                _('Tailscale connects your devices for easy access to remote resources.'),
                E('br'),
                _('One click replaces the tailscale/tailscaled binaries with the latest upstream release; init scripts, UCI config and login state are preserved.'),
                E('br'),
                _('For details see'),
                ' ',
                E('a', { 'href': 'https://tailscale.com', 'target': '_blank' }, ['tailscale'])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, [_('Status')]),
                this.statusEl
            ]),

            // settings only matter while enabled: hide them (with a hint)
            // until the Enable switch is on
            E('div', {
                'id': 'tsn-settings',
                'style': this.cfg['enabled'] === '1' ? '' : 'display:none'
            }, [
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', {}, [_('Global Settings')]),
                    E('div', { 'class': 'cbi-section-node' }, [
                        // story order: identity -> what I offer (subnet,
                        // exit node) -> what I accept -> what I use
                        this.textInput('hostname', _('Hostname'), {
                            placeholder: _('e.g. OpenWrt'),
                            descr: _('Leave empty to use the device hostname')
                        }),
                        this.textInput('advertiseRoutes', _('Advertise routes'), {
                            placeholder: _('IP addresses, comma separated'),
                            descr: E('span', {}, [_('Subnets allowed to be accessed:'), ' ', E('code', {}, [this.lanSubnet() || '192.168.100.0/24'])])
                        }),
                        this.checkBox('advertiseExitNode', _('Advertise as exit node'), _('Let other tailnet devices route their internet traffic through this router; approve the exit node in the Tailscale admin console.')),
                        this.checkBox('acceptRoutes', _('Accept subnet routes')),
                        this.textInput('exitNode', _('Use exit node'), {
                            placeholder: _('Exit node name or IP; leave empty to disable'),
                            descr: _('Exit node that routes traffic for this device: Tailscale IP (100.x.x.x) or node name, not a subnet. Leave empty to disable.')
                        }),
                        this.checkBox('exitNodeAllowLan', _('Allow LAN access while using an exit node'))
                    ])
                ]),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', {}, [_('Custom Server')]),
                    E('div', { 'class': 'cbi-section-descr' }, [
                        _('Use'),
                        ' ',
                        E('a', { 'href': 'https://github.com/juanfont/headscale', 'target': '_blank' }, ['headscale']),
                        ' ',
                        _('to deploy a private server')
                    ]),
                    E('div', { 'class': 'cbi-section-node' }, [
                        this.textInput('loginServer', _('Server URL'), {
                            placeholder: _('Headscale server URL, leave empty to disable')
                        }),
                        this.textInput('authkey', _('Auth key'), {
                            password: true,
                            placeholder: _('Auth key, leave empty to disable')
                        })
                    ])
                ]),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', {}, [_('Update Settings')]),
                    E('div', { 'class': 'cbi-section-node' }, [
                        this.checkBox('checkOnLoad', _('Check for updates'), _('Check for updates whenever this page is loaded.')),
                        this.backupSelect(),
                        this.checkBox('autoUpdate', _('Auto update'), _('Check for and install updates automatically every day at 04:30'))
                    ])
                ]),
            ]),
            E('div', {
                'id': 'tsn-settings-hint',
                'class': 'cbi-section-descr',
                'style': this.cfg['enabled'] === '1' ? 'display:none' : ''
            }, [_('Enable the service above to show the settings.')]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, [_('Tailscale Update')]),
                this.updateStateEl,
                E('div', { 'class': 'cbi-page-actions' }, [
                    E('button', {
                        'class': 'btn cbi-button-action',
                        'click': ui.createHandlerFn(this, 'handleUpdate')
                    }, [_('Update to latest now')]),
                    ' ',
                    E('button', {
                        'class': 'btn cbi-button',
                        'click': ui.createHandlerFn(this, 'handleCheck')
                    }, [_('Check for updates')]),
                    ' ',
                    E('button', {
                        'class': 'btn cbi-button-neutral',
                        'click': ui.createHandlerFn(this, 'handleRollback')
                    }, [_('Roll back')])
                ]),
                E('h3', {}, [_('Log')]),
                this.logEl
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, [_('Device requirements')]),
                E('div', { 'class': 'cbi-section-descr' }, [_('Requirements: RAM 128 MB minimum (256 MB recommended), 10 MB free on /overlay (37 MB with update backups), 30 MB free on /tmp for automatic updates.')]),
                this.reqEl
            ])
        ]);

        // fire the network-dependent probes after the page is up; panels
        // update in place when the real data lands
        this.fetchStatus().then(function (ts) {
            self.renderStatus(ts);
        });
        if (this.autocheck)
            this.checkUpdate();
        this.checkRequirements().then(function (req) {
            self.renderRequirements(req);
        });
        this.startStatusPoll();

        // resume polling if an update is already running: status=running
        // with no rc yet; never trigger on the append-only log
        Promise.all([this.readRc(), this.readStatus()]).then(function (r) {
            if ((r[0] || '').trim() === '' && (r[1] || '').trim() === 'running')
                this.startPolling();
        }.bind(this));

        return page;
    }
});
