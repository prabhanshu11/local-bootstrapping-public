// Firefox AutoConfig loader (local-bootstrapping configs/firefox-autoconfig).
// Installed to /usr/lib/firefox/defaults/pref/autoconfig.js.
// Points Firefox at firefox.cfg in the install dir; sandbox off so the cfg
// can reach Services and patch browser windows (needed to block UI gestures
// that have no about:config pref).
pref("general.config.filename", "firefox.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);
