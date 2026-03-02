#!/usr/bin/env bash
# =============================================================================
# i2pfox-install.sh — I2Pfox: The I2P Privacy Browser
# Version: 0.1.0-alpha
# =============================================================================
# Based on Tor Browser (hardened Firefox ESR) + i2pd router
# Every piece of this script is auditable — no binary blobs, no curl|bash.
#
# What this installs:
#   - ~/.local/share/i2pfox/          → config, profile, assets
#   - ~/.local/share/i2pfox/i2pd-data/→ isolated i2pd router (no transit)
#   - ~/.local/bin/i2pfox             → launcher script
#   - ~/.local/share/applications/i2pfox.desktop
#
# Dependencies: i2pd, zip, and Tor Browser (auto-detected or downloaded)
# Usage: bash i2pfox-install.sh [--tb-dir /path/to/tor-browser]
# =============================================================================
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
BASE_DIR="$HOME/.local/share/i2pfox"
PROFILE_DIR="$BASE_DIR/profile"
I2PD_DATA="$BASE_DIR/i2pd-data"
ASSETS_DIR="$BASE_DIR/assets"
EXT_DIR="$PROFILE_DIR/extensions"
EXT_ID="i2pfox-helper@i2pfox"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"

# Ports — isolated from system i2pd (default: 4444/4447/7070)
HTTP_PORT=14444
SOCKS_PORT=14447
CONSOLE_PORT=17070

# Colors for terminal output
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' N='\033[0m'

info()    { echo -e "${B}[i2pfox]${N} $*"; }
ok()      { echo -e "${G}[  OK  ]${N} $*"; }
warn()    { echo -e "${Y}[ WARN ]${N} $*"; }
die()     { echo -e "${R}[ FAIL ]${N} $*"; exit 1; }
section() { echo -e "\n${C}══ $* ══${N}"; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    section "Checking dependencies"
    local missing=()
    for cmd in i2pd zip curl; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            missing+=("$cmd")
            warn "$cmd not found"
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing: ${missing[*]}"
        sudo apt-get install -y "${missing[@]}" || die "apt install failed"
    fi
}

# ── Find Tor Browser ──────────────────────────────────────────────────────────
find_tor_browser() {
    section "Locating Tor Browser"
    local tb_arg=""
    for arg in "$@"; do
        if [[ "$arg" == "--tb-dir" ]]; then tb_arg="next"; continue; fi
        if [[ "$tb_arg" == "next" ]]; then TB_DIR="$arg"; tb_arg=""; fi
    done

    if [[ -n "${TB_DIR:-}" && -x "$TB_DIR/Browser/firefox" ]]; then
        ok "Using specified TB: $TB_DIR"
        return
    fi

    local candidates=(
        "$HOME/Desktop/tor-browser"
        "$HOME/Downloads/tor-browser"
        "$HOME/tor-browser"
        "/opt/tor-browser"
        "$HOME/.local/share/tor-browser"
    )
    for d in "${candidates[@]}"; do
        if [[ -x "$d/Browser/firefox" ]]; then
            TB_DIR="$d"
            ok "Found Tor Browser at $TB_DIR"
            return
        fi
    done

    warn "Tor Browser not found. Downloading from torproject.org..."
    local tb_url
    tb_url=$(curl -sL "https://www.torproject.org/dist/torbrowser/" \
        | grep -oP 'href="(\d+\.\d+\.\d+)/"' | tail -1 | grep -oP '"\K[^"]+')
    local version="${tb_url%/}"
    local arch="linux-x86_64"
    local tarball="tor-browser-${arch}-${version}.tar.xz"
    local dl_url="https://dist.torproject.org/torbrowser/${version}/${tarball}"

    info "Downloading Tor Browser ${version}..."
    curl -L --progress-bar -o "/tmp/${tarball}" "$dl_url" \
        || die "Failed to download Tor Browser from $dl_url"

    info "Extracting..."
    tar -xJf "/tmp/${tarball}" -C "$HOME/Downloads/" 2>/dev/null \
        || die "Failed to extract Tor Browser"
    rm -f "/tmp/${tarball}"

    TB_DIR="$HOME/Downloads/tor-browser"
    [[ -x "$TB_DIR/Browser/firefox" ]] || die "Tor Browser extraction failed"
    ok "Tor Browser installed to $TB_DIR"
}

# ── Directory structure ───────────────────────────────────────────────────────
create_dirs() {
    section "Creating directory structure"
    mkdir -p "$BASE_DIR" "$PROFILE_DIR/chrome" "$I2PD_DATA/addressbook" \
             "$ASSETS_DIR" "$EXT_DIR" "$BIN_DIR" "$APP_DIR" \
             "$BASE_DIR/i2pd-bin/lib"
    ok "Directories created under $BASE_DIR"
}

# ── Bundled i2pd binary ───────────────────────────────────────────────────────
install_i2pd_bin() {
    section "Installing bundled i2pd binary"
    local appimage="${APPIMAGE_PATH:-/media/veracrypt3/I2Pfox-x86_64.AppImage}"
    local extract_dir="/tmp/i2pfox-appimage-$$"

    if [[ ! -f "$appimage" ]]; then
        warn "AppImage not found at $appimage — skipping bundled i2pd install."
        warn "The system i2pd (/usr/bin/i2pd) will be used as fallback."
        return 0
    fi

    mkdir -p "$extract_dir"
    "$appimage" --appimage-extract 2>/dev/null 1>&2 &
    # extract runs in CWD, so we cd there first
    ( cd /tmp && "$appimage" --appimage-extract >/dev/null 2>&1 )
    local src="/tmp/squashfs-root/i2pd"
    if [[ -f "$src/i2pd" ]]; then
        cp "$src/i2pd"    "$BASE_DIR/i2pd-bin/i2pd"
        cp "$src/lib/"*   "$BASE_DIR/i2pd-bin/lib/"
        chmod +x "$BASE_DIR/i2pd-bin/i2pd"
        rm -rf /tmp/squashfs-root
        ok "Bundled i2pd installed at $BASE_DIR/i2pd-bin/"
    else
        warn "Could not extract i2pd from AppImage — system binary will be used."
        rm -rf /tmp/squashfs-root
    fi
}

# ── i2pd configuration ────────────────────────────────────────────────────────
write_i2pd_conf() {
    section "Writing i2pd config"
    cat > "$BASE_DIR/i2pd.conf" << EOF
# i2pfox — isolated i2pd instance
# --notransit: does NOT route other people's traffic
# Ports are offset +10000 from defaults to avoid conflicts with system i2pd

[httpproxy]
enabled = true
address = 127.0.0.1
port = $HTTP_PORT
# addresshelper: when a site adds ?i2paddresshelper= to the URL, i2pd
# automatically adds the hostname→destination mapping to your address book
addresshelper = true

[socksproxy]
enabled = true
address = 127.0.0.1
port = $SOCKS_PORT

[http]
enabled = true
address = 127.0.0.1
port = $CONSOLE_PORT

[ntcp2]
enabled = true
port = 0

[ssu2]
enabled = true
port = 0

[log]
level = warn

[addressbook]
# Subscription URLs — i2pd fetches these periodically to populate the address book
# These are the canonical sources for the i2p name registry
subscriptions = http://reg.i2p/hosts.txt,http://stats.i2p/cgi-bin/newhosts.txt,http://inr.i2p/export/alive-hosts.txt,http://identiguy.i2p/cgi-bin/hosts.txt
EOF
    ok "i2pd.conf written (HTTP proxy: $HTTP_PORT, SOCKS: $SOCKS_PORT, console: $CONSOLE_PORT)"
}

# ── Pre-populated address book ─────────────────────────────────────────────────
write_addressbook() {
    section "Writing pre-populated address book (79 + 4 jump services)"
    # Format: hostname.i2p,<b32address>  (no .b32.i2p suffix — i2pd internal format)
    # Jump services (hardcoded b32 from i2pd source — these are the bootstrap entries)
    cat > "$I2PD_DATA/addressbook/addresses.csv" << 'EOF'
333.i2p,ctvfe2fimcsdfxmzmd42brnbf7ceenwrbroyjx3wzah5eudjyyza
acetone.i2p,tzwfy3dnqtm4wuofmcp3gcb5qjcytri635ei7kw7yrl6n3ul5n2a
animal.i2p,5iedafy32swqq4t2wcmjb4fvg3onscng7ct7wb237jkvrclaftla
azathabar.i2p,v35rwae5zb6fcgd7phzkireghtuen43umi7l5yvahm7ezkqg5uwq
bandura.i2p,n6eqyu6glmtgt544ys43ggrozhpiw7biyrelrvmkmg7llfcjwm4a
blog.torproject.i2p,woelslt2oh4dn5wlxfmpjggyyu6l7ntgk3rngrooldn57x4kduma
ca.i2pd.i2p,u5safmawcxj5vlrdtqrsqbsndkr5cfenpicgg5euu4xqm73yicba
community.torproject.i2p,wmw22z5c24b35hlepzc2g6k3cpcg44rcg46qdwfo5heiplv7m4ca
dist.torproject.i2p,pbhgoronppg7tq3dssnwmhzkbrscbvtmy3d5pmar5hyhnqwjj46q
donate.torproject.i2p,crxdz4n5viyy46upbd4amlzxcinkea7hwj3mkiudrw3nkpnfv42q
flibusta.i2p,zmw2cyw2vj7f6obx3msmdvdepdhnw2ctc4okza2zjxlukkdfckhq
git.community.i2p,giteabolfdejtdzblkooalqei6jr67imiugmhtsh6ocw4hlj5a4q
git.idk.i2p,7qeve4v2chmjdqlwpa3vl7aojf3nodbku7vepnjwrsxljzqipz6a
gostcoin.i2p,4gzcllfxktrqzv3uys5k4vgkzbth4gqednwhfpt755yivm3davuq
hagen.i2p,e2t6rqd2ysbvs53t5nnaf7drllkgk6kfriq3lfuz6mip6xfg644q
hiddenbooru.i2p,zma5du344hy2ip5xcu6xmt4c7dgibnlv5jm4c2fre5nxv44sln3q
hiddenchan.i2p,6y4tltjdgqwfdcz6tqwc7dxhhuradop2vejatisu64nwjzh5tuwa
hotline.i2p,6cczi27iuxkm3aivazaemzltdqgh42ljzurqp43uclbz2lid2uqq
hq.postman.i2p,7ewjvbcwgah57n64cwbsxqai7eutqofkesuxfsuhfheijivdjqra
i2p-projekt.i2p,udhdrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v4jna
i2pd.i2p,4bpcp4fmvyr46vb4kqjvtxlst6puz4r3dld24umooiy5mesxzspa
i2pforum.i2p,tmipbl5d7ctnz3cib4yd2yivlrssrtpmuuzyqdpqkelzmnqllhda
i2pnews.i2p,tc73n4kivdroccekirco7rhgxdg5f3cjvbaapabupeyzrqwv5guq
identiguy.i2p,3mzmrus2oron5fxptw7hw2puho3bnqmw2hqy7nw64dsrrjwdilva
ilita.i2p,isxls447iuumsb35pq5r3di6xrxr2igugvshqwhi5hj5gvhwvqba
inr.i2p,joajgazyztfssty4w2on5oaqksz6tqoxbduy553y34mf4byv6gpq
irc.acetone.i2p,qyzbrdw26ejjdjzsrcmq5h3ggdzk6cq5xynrgee5t5q73gq545yq
irc.echelon.i2p,ez2czsvej5p3z5bquue5q3thujcodfze7ptybctqhnqc7hms5uzq
irc.ilita.i2p,5xeoyfvtddmo5k3kxzv7b3d5risil6333ntqrr3yvx3yubz5tk3a
irc.postman.i2p,hhcy7zznltay2tzwdvtd37g2inptemz3hk5zmxyi57d3sxgxbseq
irc.r4sas.i2p,hodhusp73gltozgrnianlbploon3rrvhrzfn5mf2g46o7aaau5la
isitup.i2p,xk6ypey2az23vtdkitjxvanlshztmjs2ekd6sp77m4obszf6ocfq
k1773r.i2p,zam7u6vslhemddz347uusuzjdk5wma4h5hcmcqlng4ybbpdbjhnq
kislitsa.i2p,khceo3smaxtng2tnuicmcbhdnkk2j6myi4nkigcux76qh3aabdhq
knijka.i2p,knjkodsakcxihwk5w5new76hibywia5zqcgoqgjttzsausnd22oa
legwork.i2p,cuss2sgthm5wfipnnztrjdvtaczb22hnmr2ohnaqqqz3jf6ubf3a
major.i2p,majorwsiehucyqfqbw3g2on3xqq2pwrwdd6hhyludqqr6ct7xdoa
mtproxy.ilita.i2p,vxxfipsygx6jpz57pmb3d3mjgsk5ls2idxeo2bffs3yp62muyq7q
mumble.acetone.i2p,plpu63ftpi5wdr42ew7thndoyaclrjqmcmngu2az4tahfqtfjoxa
notbob.i2p,nytzrhrjjfsutowojvxi7hphesskpqqr65wpistz6wa7cpajhp7a
nvspc.i2p,anlncoi2fzbsadbujidqmtji7hshfw3nrkqvbgdleepbxx3d5xra
obmen.i2p,vodkv54jaetjw7q2t2iethc4cbi4gjdrmw2ovfmr43mcybt7ekxa
opentracker.dg2.i2p,w7tpbzncbcocrqtwwm3nezhnnsw4ozadvi2hmvzdhrqzfxfum7wa
opentracker.r4sas.i2p,punzipidirfqspstvzpj6gb4tkuykqp6quurj6e23bgxcxhdoe7q
opentracker.skank.i2p,by7luzwhx733fhc5ug2o75dcaunblq2ztlshzd7qvptaoa73nqua
password.i2p,knmjkeabbhudejkikbzhhjqsb4r77o45vkdhve6d254quttfx3wa
pizdabol.i2p,5vik2232yfwyltuwzq7ht2yocla46q76ioacin2bfofgy63hz6wa
planet.i2p,pztcztaklof7s4me2vgtdddzesnunvk55zke6oz5e77ci3qk64yq
pomoyka.i2p,omt56v4jxa4hurbwk44vqbbcwn3eavuynyc24c25cy7grucjh24q
pool.gostcoin.i2p,m4f4k3eeaj7otbc254ccj7d5hivguqgnohwelkibr4ddk43qhywa
pop.postman.i2p,i7vd76psp3oyocljiqkoyz7fpr4fy2xq2asclf7qih6k57aj5xrq
privatebin.i2p,e7qy5kc7ivqtnrbdn5ymx5nmbdedlrjkdchqmmkhud4ockrime5a
purokishi.i2p,ia55kcrvskaitnxegirubvderl4vhva6bwkiducbkma4scy2rhca
r4sas.i2p,2gafixvoztrndawkmhfxamci5lgd3urwnilxqmlo6ittu552cndq
radio.r4sas.i2p,cv72xsje5ihg6e24atitmhyk2cbml6eggi6b6fjfh2vgw62gdpla
radioliberty.i2p,libertyx5gywnmn4snrr2fborvugmthl2x5vf3rh43v3744kmpwa
reg.i2p,shx5vqsw7usdaunyzr2qmes2fq37oumybpudrd4jjj4e4vk4uusa
repo.i2pd.i2p,ymzx5zgt6qzdg6nhxnecdgbqjd34ery6mpqolnbyo5kcwxadnodq
repo.r4sas.i2p,ymzx5zgt6qzdg6nhxnecdgbqjd34ery6mpqolnbyo5kcwxadnodq
rus.azathabar.i2p,6gp6ykan6ovr7p6dln56msvmdk6nrtvzoypz5dbhkkt4bdnryjna
rutor.i2p,rutorktnoonk3t4sxmv6g5rj6mzsilfwxcplvfybemssjrva663q
sharefile.i2p,o7jgnp7bubzdn7mxfqmghn3lzsjtpgkbnpjjsn6ddevqbchz3rta
skank.i2p,qiii4iqrj3fwv4ucaji2oykcvsob75jviycv3ghw7dhzxg2kq53q
smtp.postman.i2p,3nrunsrgeo6grhx6y6vsx7vibm5vabtockdbys3sqdmj6vha7k5q
sportloto.i2p,sportloto4cqlq6uhzzvgsgd7rcsfu6mqtk7wp6zmzqwcpflbsdq
stats.i2p,7tbay5p4kzeekxvyvbf6v7eauazemsnnl2aoyqhg5jzpr5eke7tq
support.torproject.i2p,6r7j6jlbrxb35k32zktopvr3w3pidm2baymwol33hq7xmy2sqm3a
tahoeserve.i2p,yhs7tsjeznxdenmdho5gjmk755wtredfzipb5t272oi5otipfkoa
telegram.i2p,i6jow7hymogz2s42xq62gqgej2zdm4xtnmpc6vjcwktdxpdoupja
torproject.i2p,torprojaxvxevo4c5qvor3ywgasxkubs5ukazrpq3qcxed6lgbrq
tracker2.postman.i2p,6a4kxkg5wp33p25qqhgwl6sj4yh4xuf5b3p3qldwgclebchm3eea
walker.i2p,5vik2232yfwyltuwzq7ht2yocla46q76ioacin2bfofgy63hz6wa
web.telegram.i2p,re6cgwg2yrkgaixlqvt5ufajbb3w42fsldlq7k5brpvnd5gp6x5a
wiki.i2p-projekt.i2p,b2rpg7xtzwwfvtorfkrc3m7h222qbobnklra7g4oqhfjx64k2voa
wiki.ilita.i2p,r233yskmowqe4od4he4b37wydr5fqzvj3z77v5fdei2etp2kg34a
xeha.i2p,oartgetziabrdemxctowp7bbeggc7ktmj7tr4qgk5y5jcz4prbtq
yggdrasil.acetone.i2p,tlfhgwzn4v5nlm2or5uy4leqmjbl5bncgcopbqnmcr4hbk3zrvqq
zeronet.i2p,fe6pk5sibhkr64veqxkfochdfptehyxrrbs3edwjs5ckjbjn4bna
zzz.i2p,lhbd7ojcaiofbfku7ixh47qj537g572zmhdc4oilvugzxdpdghua
EOF
    ok "Address book written: $(wc -l < "$I2PD_DATA/addressbook/addresses.csv") entries"
}

# ── PAC file — routes .i2p to i2pd, everything else direct ───────────────────
write_pac() {
    section "Writing PAC proxy config"
    cat > "$BASE_DIR/proxy.pac" << EOF
// i2pfox Proxy Auto-Config
// .i2p/.b32.i2p  → i2pd HTTP proxy ($HTTP_PORT)
// .onion          → Tor SOCKS5 (9050)
// clearnet        → Tor SOCKS5 (9050)
// localhost       → DIRECT
function FindProxyForURL(url, host) {
    // Localhost always direct
    if (host === "127.0.0.1" || host === "localhost") return "DIRECT";
    // I2P traffic through i2pd HTTP proxy
    if (shExpMatch(host, "*.i2p"))     return "PROXY 127.0.0.1:$HTTP_PORT";
    if (shExpMatch(host, "*.b32.i2p")) return "PROXY 127.0.0.1:$HTTP_PORT";
    // .onion and all clearnet through Tor
    return "SOCKS5 127.0.0.1:9050";
}
EOF
    ok "PAC written: $BASE_DIR/proxy.pac"
}

# ── Firefox profile preferences ───────────────────────────────────────────────
write_userjs() {
    section "Writing Firefox preferences"
    cat > "$PROFILE_DIR/user.js" << EOF
// i2pfox — Firefox preferences
// These are set on every launch and override prefs.js

// ── PROXY: PAC file routes .i2p → i2pd, clearnet+.onion → Tor ───────────────
user_pref("network.proxy.type", 2);  // 2 = PAC URL
user_pref("network.proxy.autoconfig_url", "file://$BASE_DIR/proxy.pac");
user_pref("network.proxy.no_proxies_on", "");
// Send DNS through the proxy — prevents .onion hostname leaks to local DNS
user_pref("network.proxy.socks_remote_dns", true);

// ── I2P COMPATIBILITY ────────────────────────────────────────────────────────
// Treat .i2p as a valid TLD (don't search for it, don't add www.)
user_pref("browser.fixup.domainsuffixwhitelist.i2p", true);
user_pref("network.IDN.whitelist.i2p", true);
// Allow HTTP on .i2p (i2p sites are not HTTPS)
user_pref("dom.security.https_only_mode", false);
user_pref("dom.security.https_only_mode_ever_enabled", false);
user_pref("network.stricttransportsecurity.preloadlist", false);
// Allow the proxy to handle .i2p hostnames (don't resolve locally)
user_pref("network.proxy.allow_hijacking_localhost", true);

// ── THEME: enable userChrome.css ─────────────────────────────────────────────
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// ── TORBUTTON: use our own proxy, not Tor ────────────────────────────────────
user_pref("extensions.torbutton.use_nontor_proxy", true);
user_pref("extensions.torlauncher.start_tor", false);

// ── PRIVACY ──────────────────────────────────────────────────────────────────
user_pref("geo.enabled", false);
user_pref("media.peerconnection.enabled", false);      // Disable WebRTC
user_pref("media.navigator.enabled", false);
user_pref("browser.safebrowsing.enabled", false);
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("browser.ping-centre.telemetry", false);

// ── EXTENSION LOADING ────────────────────────────────────────────────────────
user_pref("xpinstall.signatures.required", false);
user_pref("extensions.autoDisableScopes", 0);
user_pref("extensions.enabledScopes", 15);
user_pref("extensions.startupScanScopes", 7);

// ── HOME PAGE: status server (http avoids file:// fetch restrictions) ────────
user_pref("browser.startup.homepage", "http://127.0.0.1:17071/");
user_pref("browser.newtab.url", "http://127.0.0.1:17071/");
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.startup.page", 1);

// ── UI ────────────────────────────────────────────────────────────────────────
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.firstrunSkipsHomepage", true);
user_pref("extensions.pocket.enabled", false);
user_pref("browser.uidensity", 0);
user_pref("browser.tabs.drawInTitlebar", true);
user_pref("browser.toolbars.bookmarks.visibility", "always");

// ── SEARCH ENGINE: 4get.ca ───────────────────────────────────────────────────
user_pref("browser.search.defaultenginename", "4get");
user_pref("browser.search.selectedEngine", "4get");
user_pref("browser.urlbar.placeholderName", "4get");
user_pref("browser.search.geoSpecificDefaults", false);
user_pref("browser.search.geoip.url", "");
EOF
    ok "user.js written"
}

# ── 4get search engine (searchplugins/) ──────────────────────────────────────
write_searchplugins() {
    section "Writing search engine (4get.ca)"
    mkdir -p "$PROFILE_DIR/searchplugins"
    cat > "$PROFILE_DIR/searchplugins/4get.xml" << 'EOF'
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"
                       xmlns:moz="http://www.mozilla.org/2006/browser/search/">
  <ShortName>4get</ShortName>
  <Description>4get.ca — private search, no tracking</Description>
  <InputEncoding>UTF-8</InputEncoding>
  <Image width="16" height="16" type="image/x-icon">https://4get.ca/favicon.ico</Image>
  <Url type="text/html" method="GET" template="https://4get.ca/web?s={searchTerms}"/>
  <Url type="application/x-suggestions+json" method="GET" template="https://4get.ca/api/suggestions?query={searchTerms}"/>
  <moz:SearchForm>https://4get.ca/</moz:SearchForm>
</OpenSearchDescription>
EOF
    # Remove cached search DB so Firefox rebuilds from searchplugins/
    rm -f "$PROFILE_DIR/search.json.mozlz4"
    ok "search engine written"
}

# ── Blue fox theme (userChrome.css) ──────────────────────────────────────────
write_userchrome() {
    section "Writing blue fox theme"
    cat > "$PROFILE_DIR/chrome/userChrome.css" << 'EOF'
/* i2pfox — Blue Privacy Browser Theme */
@namespace url("http://www.mozilla.org/keymaster/gatekeeper/there.is.only.xul");

:root {
  --ifox-darkblue:  #08224f;
  --ifox-midblue:   #1060d0;
  --ifox-accent:    #3d8ef0;
  --ifox-light:     #a8c8ff;
  --ifox-white:     #e8f0fe;
  --ifox-hover:     rgba(255,255,255,0.12);
  --ifox-border:    rgba(61,142,240,0.4);
}

/* ── Toolbox: hardcode colors directly so Tor Browser's LWT can't override ── */
#navigator-toolbox,
#navigator-toolbox > toolbar,
#navigator-toolbox toolbar,
#nav-bar,
#TabsToolbar,
#toolbar-menubar,
#PersonalToolbar {
  background-color: #08224f !important;
  background-image: none !important;
  color: #e8f0fe !important;
  border-bottom: none !important;
}

#navigator-toolbox {
  border-bottom: 2px solid #3d8ef0 !important;
}

/* ── Tabs ── */
.tabbrowser-tab[selected="true"] .tab-background {
  background-color: #1060d0 !important;
  border-radius: 4px 4px 0 0 !important;
}
.tabbrowser-tab:not([selected]) .tab-background:hover {
  background-color: var(--ifox-hover) !important;
}
.tab-label,
.tab-text,
.tabbrowser-tab .tab-label,
.tabbrowser-tab .tab-text,
.tabbrowser-tab[selected] .tab-label,
.tabbrowser-tab:not([selected]) .tab-label,
.tabbrowser-tab[fadein] .tab-label,
.tabbrowser-tab[visuallyselected] .tab-label,
tab .tab-label,
tab label {
  color: #e8f0fe !important;
  text-shadow: none !important;
  opacity: 1 !important;
}
/* Selected tab — brighter white so it stands out */
.tabbrowser-tab[selected="true"] .tab-label,
.tabbrowser-tab[visuallyselected="true"] .tab-label {
  color: #ffffff !important;
  font-weight: 500 !important;
}

/* ── URL bar ── */
#urlbar-background {
  background-color: rgba(255,255,255,0.10) !important;
  border: 1px solid var(--ifox-border) !important;
  border-radius: 6px !important;
}
#urlbar[focused="true"] #urlbar-background {
  background-color: rgba(255,255,255,0.16) !important;
  border-color: var(--ifox-accent) !important;
  box-shadow: 0 0 0 2px rgba(61,142,240,0.3) !important;
}
#urlbar-input,
#urlbar .urlbar-input,
#urlbar input,
.urlbar-input-box input,
.urlbar-input-box > input,
#urlbar[focused] #urlbar-input,
#urlbar:not([focused]) #urlbar-input {
  color: #e8f0fe !important;
  -moz-appearance: none !important;
}
#urlbar,
#nav-bar {
  --input-color: #e8f0fe !important;
  --toolbar-field-color: #e8f0fe !important;
  --toolbar-field-focus-color: #e8f0fe !important;
  color: #e8f0fe !important;
}
.urlbar-scheme { color: var(--ifox-light) !important; opacity: 0.8; }

/* ── "Not Secure" / identity label ── */
#identity-icon-label,
#identity-box,
#identity-box .identity-icon-label,
.identity-icon-label,
#urlbar-label-box {
  color: #e8f0fe !important;
  opacity: 1 !important;
}

/* ── Toolbar buttons ── */
.toolbarbutton-1 { color: var(--ifox-white) !important; }
.toolbarbutton-1:hover > .toolbarbutton-icon,
.toolbarbutton-1:hover > .toolbarbutton-text {
  background-color: var(--ifox-hover) !important;
  border-radius: 4px !important;
}

/* ── Menu bar ── */
#toolbar-menubar, menubar {
  background-color: var(--ifox-darkblue) !important;
}
.menubar-item { color: var(--ifox-white) !important; }
.menubar-item:hover {
  background-color: var(--ifox-midblue) !important;
  color: white !important;
}

/* ── Bookmarks toolbar ── */
#PersonalToolbar {
  background-color: #0d2e6a !important;
  border-top: 1px solid var(--ifox-border) !important;
}
.bookmark-item .toolbarbutton-text { color: var(--ifox-light) !important; }
.bookmark-item:hover { background-color: var(--ifox-hover) !important; }

/* ── i2p address bar badge — .i2p sites shown with special color ── */
#urlbar-label-box[value="i2p"] {
  background-color: var(--ifox-midblue) !important;
  color: white !important;
}

/* ── Search/URL bar icons — force light color so visible on dark toolbar ── */
#searchmode-switcher-chiclet,
#urlbar-searchmode-switcher,
.searchmode-switcher-icon,
#urlbar-search-button,
.urlbar-icon,
.urlbar-page-action,
#page-action-buttons .urlbar-page-action,
#urlbar .urlbar-go-button,
#urlbar .urlbar-revert-button,
.search-go-button,
.urlbar-history-dropmarker {
  color: #e8f0fe !important;
  fill: #e8f0fe !important;
  -moz-context-properties: fill;
}

/* ── Hide Firefox sync button (not needed) ── */
#fxa-toolbar-menu-button { display: none !important; }

/* ── Network-aware toolbar colors (set by userChrome.js via data-network attr) ── */
:root[data-network="i2p"] #navigator-toolbox,
:root[data-network="i2p"] #navigator-toolbox > toolbar,
:root[data-network="i2p"] #navigator-toolbox toolbar,
:root[data-network="i2p"] #nav-bar,
:root[data-network="i2p"] #TabsToolbar,
:root[data-network="i2p"] #toolbar-menubar,
:root[data-network="i2p"] #PersonalToolbar {
  background-color: #2d0a4e !important;
}
:root[data-network="i2p"] #navigator-toolbox {
  border-bottom: 2px solid #a855f7 !important;
}
:root[data-network="i2p"] .tabbrowser-tab[selected="true"] .tab-background {
  background-color: #6d28d9 !important;
}

:root[data-network="tor"] #navigator-toolbox,
:root[data-network="tor"] #navigator-toolbox > toolbar,
:root[data-network="tor"] #navigator-toolbox toolbar,
:root[data-network="tor"] #nav-bar,
:root[data-network="tor"] #TabsToolbar,
:root[data-network="tor"] #toolbar-menubar,
:root[data-network="tor"] #PersonalToolbar {
  background-color: #0a2e1a !important;
}
:root[data-network="tor"] #navigator-toolbox {
  border-bottom: 2px solid #10b981 !important;
}
:root[data-network="tor"] .tabbrowser-tab[selected="true"] .tab-background {
  background-color: #065f46 !important;
}
EOF
    ok "userChrome.css written"
}

# ── Chrome JS for network-aware coloring ─────────────────────────────────────
write_userchromejs() {
    section "Writing userChrome.js"
    cat > "$PROFILE_DIR/chrome/userChrome.js" << 'EOF'
// i2pfox — network-aware tab coloring
(function() {
  function getNetwork(url) {
    if (!url) return "clearnet";
    if (/\.i2p(\/|$|:)/.test(url) || url.startsWith("http://127.0.0.1:17071")) return "i2p";
    if (/\.onion(\/|$|:)/.test(url)) return "tor";
    return "clearnet";
  }
  function applyNetwork(url) {
    document.documentElement.setAttribute("data-network", getNetwork(url));
  }
  var gb = gBrowser;
  gb.tabContainer.addEventListener("TabSelect", function() {
    applyNetwork(gb.currentURI ? gb.currentURI.spec : "");
  });
  gb.addTabsProgressListener({
    onLocationChange: function(browser, req, uri) {
      if (browser === gb.selectedBrowser) applyNetwork(uri ? uri.spec : "");
    }
  });
  applyNetwork(gb.currentURI ? gb.currentURI.spec : "");
})();
EOF
    ok "userChrome.js written"
}

# ── Router console theme (userContent.css) ───────────────────────────────────
write_usercontent() {
    cat > "$PROFILE_DIR/chrome/userContent.css" << EOF
/* Style the i2pd console to match i2pfox blue theme */
@-moz-document url-prefix("http://127.0.0.1:$CONSOLE_PORT/") {
  :root {
    --bg: #08224f;
    --panel: #0d2e6a;
    --accent: #3d8ef0;
    --text: #e8f0fe;
    --link: #80b8ff;
    --border: rgba(61,142,240,0.3);
  }
  body {
    background: var(--bg) !important;
    color: var(--text) !important;
    font-family: system-ui, sans-serif !important;
  }
  a { color: var(--link) !important; }
  a:hover { color: #ffffff !important; }
  table { border-collapse: collapse !important; }
  td, th {
    border: 1px solid var(--border) !important;
    padding: 4px 8px !important;
    color: var(--text) !important;
  }
  th { background: var(--panel) !important; color: var(--accent) !important; }
  tr:hover td { background: rgba(61,142,240,0.08) !important; }
  .header, h1, h2, h3 { color: var(--accent) !important; }
}
EOF
    ok "userContent.css written (console themed)"
}

# ── Startup home page ─────────────────────────────────────────────────────────
write_home() {
    section "Writing home.html (live i2pd status page)"
    cat > "$PROFILE_DIR/home.html" << 'HOMEEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Welcome to I2Pfox</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#020c1b;color:#cce4f7;font-family:'Segoe UI',system-ui,sans-serif;
       min-height:100vh;display:flex;align-items:center;justify-content:center}
  .card{background:#0a1f3d;border:1px solid #1d6fa4;border-radius:12px;
        padding:2.5rem 3rem;text-align:center;max-width:520px;width:90%}
  .hex{font-size:2.8rem;color:#4db8ff;font-weight:900;letter-spacing:4px;margin-bottom:.4rem}
  h1{font-size:1.5rem;font-weight:300;color:#cce4f7;margin-bottom:1.4rem}
  .btn{display:inline-block;margin-top:1.4rem;padding:.65rem 2rem;background:#1d6fa4;
       color:#fff;border-radius:6px;text-decoration:none;font-weight:bold;letter-spacing:1px}
  .btn:hover{background:#2589c8}
  .note{margin-top:1.8rem;font-size:.78rem;color:#4a7a9b;line-height:1.7}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;
       background:#1d6fa4;margin-right:6px;vertical-align:middle}

  /* Status widget */
  #status-box{
    margin:1.4rem 0 0.4rem;
    background:#06162c;border:1px solid #1a4a70;border-radius:8px;
    padding:.9rem 1.2rem;text-align:left;font-size:.82rem;
  }
  #status-box .row{display:flex;justify-content:space-between;align-items:center;
                   padding:.18rem 0;border-bottom:1px solid #0d2a45;}
  #status-box .row:last-child{border-bottom:none}
  #status-box .lbl{color:#4a7a9b}
  #status-box .val{font-weight:600;color:#cce4f7}
  #status-box .val.ok   {color:#3ddc84}
  #status-box .val.warn {color:#f0c040}
  #status-box .val.bad  {color:#ff6b6b}
  #status-box .val.spin::after{content:'';display:inline-block;width:10px;height:10px;
    border:2px solid #4a7a9b;border-top-color:#4db8ff;border-radius:50%;
    animation:spin .8s linear infinite;margin-left:6px;vertical-align:middle}
  @keyframes spin{to{transform:rotate(360deg)}}

  #progress-track{height:4px;background:#06162c;border-radius:2px;
                  overflow:hidden;margin:.6rem 0 0}
  #progress-bar{height:4px;background:linear-gradient(90deg,#1d6fa4,#4db8ff);
                width:0%;border-radius:2px;transition:width .4s ease}
  #status-msg{margin-top:.55rem;font-size:.75rem;color:#4a7a9b;text-align:center;
              min-height:1em}
</style>
</head>
<body>
<div class="card">
  <div class="hex">&#x2B21; I2PFOX</div>
  <h1>Welcome to I2Pfox</h1>

  <div id="status-box">
    <div class="row"><span class="lbl">Router status</span> <span id="s-status" class="val spin">starting</span></div>
    <div class="row"><span class="lbl">Known peers</span>   <span id="s-peers"  class="val">—</span></div>
    <div class="row"><span class="lbl">Active tunnels</span><span id="s-tunnels"class="val">—</span></div>
    <div class="row"><span class="lbl">In / Out bandwidth</span><span id="s-bw" class="val">—</span></div>
  </div>
  <div id="progress-track"><div id="progress-bar"></div></div>
  <div id="status-msg">Connecting to I2P network…</div>

  <a class="btn" href="http://127.0.0.1:17070">I2P Router Console &#x2192;</a>

  <div class="note">
    <span class="dot"></span>HTTP proxy: 127.0.0.1:14444<br>
    <span class="dot"></span>Your regular Firefox bookmarks, passwords, history and extensions are completely invisible to I2Pfox<br>
    <span class="dot"></span>I2Pfox browsing history, cookies and session data can&rsquo;t leak into your regular Firefox<br>
    <span class="dot"></span>You can run both simultaneously without interfering<br>
    <span class="dot"></span>No telemetry &middot; No WebRTC
  </div>
</div>

<script>
const READY_PEERS = 50;
let pollInterval = 2000;
let ready = false;

async function poll() {
  try {
    const res = await fetch('/status', {cache:'no-store'});
    const d   = await res.json();

    document.getElementById('s-peers').textContent   = d.peers;
    document.getElementById('s-tunnels').textContent = d.tunnels;
    document.getElementById('s-bw').textContent      = `${d.bw_in} / ${d.bw_out} KiB/s`;

    const pct = Math.min(100, Math.round(d.peers / READY_PEERS * 100));
    document.getElementById('progress-bar').style.width = pct + '%';

    const sEl = document.getElementById('s-status');
    if (!d.up || d.peers === 0) {
      sEl.textContent = 'bootstrapping'; sEl.className = 'val spin';
      document.getElementById('status-msg').textContent = 'Connecting to I2P network…';
    } else if (d.peers < 10) {
      sEl.textContent = 'building tunnels'; sEl.className = 'val warn';
      document.getElementById('status-msg').textContent = `Found ${d.peers} peers — building tunnels…`;
    } else {
      sEl.textContent = 'Ready'; sEl.className = 'val ok';
      document.getElementById('status-msg').textContent =
        `${d.peers} peers · ${d.tunnels} active tunnels — you can browse .i2p sites`;
      if (!ready) { ready = true; pollInterval = 8000; }
    }
  } catch(e) {
    const sEl = document.getElementById('s-status');
    sEl.textContent = 'starting'; sEl.className = 'val spin';
    document.getElementById('status-msg').textContent = 'Waiting for i2pd to start…';
  }
  setTimeout(poll, pollInterval);
}

poll();
</script>
</body>
</html>
HOMEEOF
    ok "home.html written"
}

# ── Status server ─────────────────────────────────────────────────────────────
write_status_server() {
    section "Writing status-server.py"
    cat > "$BASE_DIR/status-server.py" << 'EOF'
#!/usr/bin/env python3
# i2pfox status server — serves home.html and proxies /status to i2pd console
# Runs on 127.0.0.1:17071. Fully auditable plain text.
import http.server, urllib.request, json, re, os, sys

PORT      = 17071
CONSOLE   = 'http://127.0.0.1:17070/'
HOME_FILE = os.path.join(os.path.dirname(__file__), 'profile', 'home.html')

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path == '/status':
            self._status()
        else:
            self._home()

    def _status(self):
        try:
            html = urllib.request.urlopen(CONSOLE, timeout=3).read().decode('utf-8', errors='ignore')
            peers   = int((re.search(r'Routers:</b>\s*(\d+)',        html) or ['','0'])[1] or 0)
            tunnels = int((re.search(r'Client Tunnels:</b>\s*(\d+)', html) or ['','0'])[1] or 0)
            bw_in   =    (re.search(r'Received:.*?([\d.]+)\s*KiB/s', html) or ['','0'])[1]
            bw_out  =    (re.search(r'Sent:.*?([\d.]+)\s*KiB/s',     html) or ['','0'])[1]
            data = {'up': True, 'peers': peers, 'tunnels': tunnels,
                    'bw_in': bw_in, 'bw_out': bw_out}
        except Exception:
            data = {'up': False, 'peers': 0, 'tunnels': 0, 'bw_in': '0', 'bw_out': '0'}
        self._json(data)

    def _home(self):
        try:
            with open(HOME_FILE, 'rb') as f:
                body = f.read()
            self._send(200, 'text/html; charset=utf-8', body)
        except Exception:
            self._send(404, 'text/plain', b'not found')

    def _json(self, d):
        self._send(200, 'application/json', json.dumps(d).encode())

    def _send(self, code, ct, body):
        self.send_response(code)
        self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    http.server.HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
EOF
    ok "status-server.py written"
}

write_extension() {
    section "Writing auto-resolve extension"
    local ext_build="/tmp/i2pfox-ext-$$"
    mkdir -p "$ext_build"

    # manifest.json
    cat > "$ext_build/manifest.json" << EOF
{
  "manifest_version": 2,
  "name": "I2Pfox Address Helper",
  "version": "1.0.0",
  "description": "Automatically resolves unknown i2p hostnames via jump services and adds them to your local address book.",
  "browser_specific_settings": {
    "gecko": { "id": "$EXT_ID", "strict_min_version": "68.0" }
  },
  "content_scripts": [{
    "matches": ["http://*.i2p/*", "http://*.b32.i2p/*"],
    "js": ["addresshelper.js"],
    "run_at": "document_end",
    "all_frames": false
  }]
}
EOF

    # addresshelper.js
    # Strategy: when i2pd returns its "Host not found" error page, this script:
    # 1. Detects the error (title = "I2Pd HTTP proxy")
    # 2. Extracts the jump service links i2pd already provides in the error page
    # 3. Fetches each one (through the i2pd proxy, so they work over i2p)
    # 4. Scans the response for any ?i2paddresshelper=DESTINATION link
    # 5. Navigates to http://hostname.i2p/?i2paddresshelper=DEST
    # 6. i2pd sees the addresshelper param, adds hostname→dest to address book,
    #    then proxies the request transparently
    # The user sees a brief "Resolving..." screen, then the site loads.
    cat > "$ext_build/addresshelper.js" << 'JSEOF'
(function () {
  'use strict';

  const TIMEOUT_MS = 20000;

  // ── Detect i2pd's "host not found" error page ──────────────────────────────
  function isI2pdErrorPage() {
    return document.title === 'I2Pd HTTP proxy' &&
      document.body &&
      document.body.innerText.includes('not found');
  }

  // ── Extract the jump service links i2pd already put in the error page ──────
  // i2pd's error page includes an <ul> of jump service <a> tags pointing to
  // reg.i2p, stats.i2p, identiguy.i2p, and notbob.i2p — each with the
  // unknown hostname already embedded in the query string.
  function getJumpLinks() {
    const links = [];
    document.querySelectorAll('a[href]').forEach(a => {
      const href = a.href;
      if (href && (
        href.includes('.b32.i2p') ||
        href.includes('jump') ||
        href.includes('hosts.cgi') ||
        href.includes('query')
      )) {
        links.push(href);
      }
    });
    return links;
  }

  // ── Extract any i2paddresshelper destination from HTML ─────────────────────
  // Jump services respond with a page containing a link like:
  //   <a href="http://forum.i2p/?i2paddresshelper=VERY_LONG_BASE64=">Jump</a>
  // We scan all links on the response page for this pattern.
  function extractAddresshelper(html) {
    const match = html.match(/[?&]i2paddresshelper=([A-Za-z0-9+\/=\-~]{100,})/);
    return match ? match[1] : null;
  }

  // ── Fetch with timeout ─────────────────────────────────────────────────────
  function fetchWithTimeout(url, ms) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), ms);
    return fetch(url, { signal: ctrl.signal })
      .then(r => { clearTimeout(timer); return r; })
      .catch(e => { clearTimeout(timer); throw e; });
  }

  // ── Show resolving UI ──────────────────────────────────────────────────────
  function showResolving(hostname) {
    document.title = `Resolving ${hostname}…`;
    document.body.innerHTML = `
      <style>
        body { margin:0; background:#08224f; color:#e8f0fe;
               font-family:system-ui,sans-serif; display:flex;
               align-items:center; justify-content:center; min-height:100vh; }
        .box { text-align:center; max-width:480px; padding:24px; }
        h2   { color:#3d8ef0; margin:0 0 12px; font-size:1.4em; }
        p    { color:#a8c8ff; margin:4px 0; }
        #msg { color:#3d8ef0; margin-top:18px; font-size:.9em; min-height:1.4em; }
        .fox { font-size:56px; margin-bottom:16px; }
        .err { color:#ff7070; }
        a    { color:#80b8ff; }
      </style>
      <div class="box">
        <div class="fox">🦊</div>
        <h2>Resolving ${hostname}</h2>
        <p>Querying i2p jump services…</p>
        <div id="msg"></div>
      </div>`;
    return document.getElementById('msg');
  }

  // ── Main ───────────────────────────────────────────────────────────────────
  async function main() {
    if (!isI2pdErrorPage()) return;

    const hostname = window.location.hostname;
    if (!hostname || !hostname.endsWith('.i2p')) return;

    const statusEl = showResolving(hostname);
    const jumpLinks = getJumpLinks();

    if (jumpLinks.length === 0) {
      statusEl.innerHTML =
        '<span class="err">No jump services available. Is i2pd running?</span>';
      return;
    }

    for (const jumpUrl of jumpLinks) {
      try {
        const svcName = new URL(jumpUrl).hostname.replace('.b32.i2p', '.i2p');
        if (statusEl) statusEl.textContent = `Trying ${svcName}…`;

        const resp = await fetchWithTimeout(jumpUrl, TIMEOUT_MS);
        if (!resp.ok) continue;

        const html = await resp.text();
        const dest = extractAddresshelper(html);
        if (!dest) continue;

        // Preserve the original path the user wanted
        const origPath = window.location.pathname || '/';
        const origSearch = window.location.search
          .replace(/[?&]i2paddresshelper=[^&]*/g, '').replace(/^&/, '?') || '';

        // Navigate to the addresshelper URL.
        // i2pd detects ?i2paddresshelper=DEST, records hostname→dest in the
        // local address book, strips the param, and proxies the real request.
        if (statusEl) statusEl.textContent = 'Address found! Loading…';
        const sep = origSearch ? '&' : '?';
        window.location.href =
          `http://${hostname}${origPath}${origSearch}${sep}i2paddresshelper=${dest}`;
        return;

      } catch (_) {
        // Try next service
      }
    }

    if (statusEl) {
      statusEl.innerHTML =
        `<span class="err">Could not resolve ${hostname}.<br>` +
        `All jump services timed out or returned no result.</span><br><br>` +
        `<a href="http://notbob.i2p/">Browse known I2P sites at notbob.i2p</a>`;
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
JSEOF

    # Package as .xpi (just a zip with .xpi extension)
    (cd "$ext_build" && zip -q "$EXT_DIR/${EXT_ID}.xpi" manifest.json addresshelper.js)
    rm -rf "$ext_build"
    ok "Extension packaged: $EXT_DIR/${EXT_ID}.xpi"
}

# ── Network Indicator Extension ───────────────────────────────────────────────
write_network_extension() {
    section "Writing network indicator extension"
    local NET_ID="network-indicator@i2pfox"
    local net_build
    net_build="$(mktemp -d)"

    cat > "$net_build/manifest.json" << 'EOF'
{
  "manifest_version": 2,
  "name": "I2Pfox Network Indicator",
  "version": "1.1",
  "description": "Colors the tab bar by network: purple=I2P, green=Tor, blue=clearnet",
  "permissions": ["tabs", "theme"],
  "background": { "scripts": ["background.js"] },
  "chrome_url_overrides": { "newtab": "newtab.html" },
  "browser_specific_settings": {
    "gecko": { "id": "network-indicator@i2pfox" }
  }
}
EOF

    cat > "$net_build/newtab.html" << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<link rel="icon" type="image/svg+xml" href="fox.svg">
<script>window.location.replace("http://127.0.0.1:17071/");</script>
</head><body></body></html>
EOF

    # Copy fox.svg into extension so newtab favicon works offline
    cp "$ASSETS_DIR/fox.svg" "$net_build/fox.svg"

    cat > "$net_build/background.js" << 'EOF'
// I2Pfox Network Indicator
// Changes tab line + toolbar tint based on active tab domain:
//   .i2p   → purple
//   .onion → green
//   other  → blue (default)

const BASE = {
  frame:                "#08224f",
  tab_background_text:  "#e8f0fe",
  tab_text:             "#ffffff",
  toolbar:              "#0d2e6a",
  toolbar_text:         "#e8f0fe",
  toolbar_field:        "rgba(255,255,255,0.10)",
  toolbar_field_text:   "#e8f0fe",
  toolbar_field_focus:  "rgba(255,255,255,0.16)",
  bookmark_text:        "#e8f0fe",
  button_background_hover: "rgba(255,255,255,0.12)",
};

const NETWORKS = {
  i2p: {
    tab_line: "#a855f7",
    frame:    "#130a2e",
    toolbar:  "#1a0d45",
  },
  tor: {
    tab_line: "#10b981",
    frame:    "#0a2218",
    toolbar:  "#0d3324",
  },
  clearnet: {
    tab_line: "#3d8ef0",
    frame:    BASE.frame,
    toolbar:  BASE.toolbar,
  },
  local: {
    tab_line: "#3d8ef0",
    frame:    BASE.frame,
    toolbar:  BASE.toolbar,
  },
};

function getNetwork(url) {
  try {
    const host = new URL(url).hostname;
    if (!host || host === "127.0.0.1" || host === "localhost") return "local";
    if (host.endsWith(".i2p"))   return "i2p";
    if (host.endsWith(".onion")) return "tor";
    return "clearnet";
  } catch (_) { return "local"; }
}

async function applyTheme(tabId) {
  try {
    const tab = await browser.tabs.get(tabId);
    const net = getNetwork(tab.url || "");
    browser.theme.update({ colors: { ...BASE, ...NETWORKS[net] } });
  } catch (_) {}
}

browser.tabs.onActivated.addListener(({ tabId }) => applyTheme(tabId));
browser.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.url && tab.active) applyTheme(tabId);
});
EOF

    (cd "$net_build" && zip -q "$EXT_DIR/${NET_ID}.xpi" manifest.json background.js)
    rm -rf "$net_build"
    ok "Network indicator packaged: $EXT_DIR/${NET_ID}.xpi"
}

# ── Bookmarks ─────────────────────────────────────────────────────────────────
write_bookmarks() {
    section "Writing bookmarks"
    cat > "$PROFILE_DIR/bookmarks.html" << 'EOF'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>I2Pfox Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>

<DT><H3>🦊 I2Pfox</H3>
<DL><p>
  <DT><A HREF="http://127.0.0.1:17070/">I2P Router Console</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=addressbook">Address Book</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=tunnels">Tunnels</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=i2ptunnels">Local Destinations</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=transit">Transit Tunnels</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=peers">Peers</A>
  <DT><A HREF="http://127.0.0.1:17070/?page=netdb">Network DB</A>
</DL><p>

<DT><H3>🌐 I2P Network</H3>
<DL><p>
  <DT><A HREF="http://i2p-projekt.i2p/">I2P Project</A>
  <DT><A HREF="http://i2pd.i2p/">i2pd (C++ router)</A>
  <DT><A HREF="http://stats.i2p/">Network Statistics</A>
  <DT><A HREF="http://inr.i2p/">INR Name Registry</A>
  <DT><A HREF="http://planet.i2p/">Planet I2P (blog aggregator)</A>
  <DT><A HREF="http://i2pnews.i2p/">I2P News</A>
</DL><p>

<DT><H3>🔍 Search</H3>
<DL><p>
  <DT><A HREF="http://stats.i2p/cgi-bin/search.cgi">Stats.i2p Search</A>
</DL><p>

<DT><H3>💬 Forums & Community</H3>
<DL><p>
  <DT><A HREF="http://i2pforum.i2p/">I2P Forum</A>
  <DT><A HREF="http://zzz.i2p/">zzz.i2p (developer forum)</A>
  <DT><A HREF="http://hiddenchan.i2p/">Hiddenchan</A>
  <DT><A HREF="http://ilita.i2p/">Ilita</A>
</DL><p>

<DT><H3>🛠️ Development</H3>
<DL><p>
  <DT><A HREF="http://git.idk.i2p/">IDK Git</A>
  <DT><A HREF="http://git.community.i2p/">Community Git</A>
  <DT><A HREF="http://repo.i2pd.i2p/">i2pd Package Repo</A>
  <DT><A HREF="http://wiki.i2p-projekt.i2p/">I2P Wiki</A>
</DL><p>

<DT><H3>📦 Files & Torrents</H3>
<DL><p>
  <DT><A HREF="http://tracker2.postman.i2p/">Postman Tracker</A>
  <DT><A HREF="http://opentracker.dg2.i2p/">DG2 Tracker</A>
  <DT><A HREF="http://flibusta.i2p/">Flibusta (books)</A>
  <DT><A HREF="http://sharefile.i2p/">ShareFile</A>
</DL><p>

<DT><H3>📬 Mail & Messaging</H3>
<DL><p>
  <DT><A HREF="http://hq.postman.i2p/">Postman Mail</A>
  <DT><A HREF="http://irc.acetone.i2p/">Acetone IRC</A>
</DL><p>

</DL>
EOF
    # Tell Firefox to import this file on first run
    echo 'user_pref("browser.bookmarks.file", "'"$PROFILE_DIR/bookmarks.html"'");' >> "$PROFILE_DIR/user.js"
    echo 'user_pref("browser.places.importBookmarksHTML", true);'                   >> "$PROFILE_DIR/user.js"
    ok "Bookmarks written"
}

# ── Fox SVG icon ──────────────────────────────────────────────────────────────
write_fox_svg() {
    section "Writing fox icon"
    cat > "$ASSETS_DIR/fox.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <!-- Pointy ears -->
  <polygon points="14,52 24,16 40,42" fill="#08224f"/>
  <polygon points="60,42 76,16 86,52" fill="#08224f"/>
  <!-- Inner ear glow -->
  <polygon points="18,49 24,24 36,42" fill="#1060d0"/>
  <polygon points="64,42 76,24 82,49" fill="#1060d0"/>
  <!-- Head -->
  <ellipse cx="50" cy="60" rx="33" ry="29" fill="#1060d0"/>
  <!-- Cheek fluff -->
  <ellipse cx="20" cy="65" rx="11" ry="9" fill="#1060d0"/>
  <ellipse cx="80" cy="65" rx="11" ry="9" fill="#1060d0"/>
  <!-- Face mask (lighter) -->
  <ellipse cx="50" cy="70" rx="21" ry="17" fill="#5090f0"/>
  <!-- Eyes -->
  <ellipse cx="37" cy="54" rx="6.5" ry="7.5" fill="#08224f"/>
  <ellipse cx="63" cy="54" rx="6.5" ry="7.5" fill="#08224f"/>
  <!-- Pupils -->
  <ellipse cx="38" cy="55" rx="3.5" ry="5" fill="#1060d0"/>
  <ellipse cx="64" cy="55" rx="3.5" ry="5" fill="#1060d0"/>
  <!-- Eye shine -->
  <circle cx="39.5" cy="51.5" r="2.2" fill="white" opacity="0.85"/>
  <circle cx="65.5" cy="51.5" r="2.2" fill="white" opacity="0.85"/>
  <!-- Nose -->
  <ellipse cx="50" cy="71" rx="5" ry="4" fill="#08224f"/>
  <circle cx="48.5" cy="71" r="1.5" fill="#1a4080"/>
  <circle cx="51.5" cy="71" r="1.5" fill="#1a4080"/>
  <!-- Mouth -->
  <path d="M44,76 Q50,82 56,76" fill="none" stroke="#08224f"
        stroke-width="2.2" stroke-linecap="round"/>
  <!-- Whiskers -->
  <line x1="12" y1="64" x2="34" y2="69" stroke="#a8c8ff" stroke-width="1.2" opacity="0.55"/>
  <line x1="12" y1="69" x2="34" y2="71" stroke="#a8c8ff" stroke-width="1.2" opacity="0.55"/>
  <line x1="66" y1="69" x2="88" y2="64" stroke="#a8c8ff" stroke-width="1.2" opacity="0.55"/>
  <line x1="66" y1="71" x2="88" y2="69" stroke="#a8c8ff" stroke-width="1.2" opacity="0.55"/>
</svg>
EOF
    # Convert to PNG for desktop entry (use ImageMagick if available)
    if command -v convert &>/dev/null; then
        convert -background none "$ASSETS_DIR/fox.svg" \
            -resize 128x128 "$ASSETS_DIR/fox.png" 2>/dev/null && ok "fox.png generated"
    fi
    ok "fox.svg written"
}

# ── Launcher script ───────────────────────────────────────────────────────────
write_launcher() {
    section "Writing launcher"
    cat > "$BIN_DIR/i2pfox" << EOF
#!/usr/bin/env bash
# i2pfox launcher — starts isolated i2pd, then opens the browser
# Fully auditable: every component is a readable text file in ~/.local/share/i2pfox/

BASE_DIR="\$HOME/.local/share/i2pfox"
I2PD_CONF="\$BASE_DIR/i2pd.conf"
I2PD_DATA="\$BASE_DIR/i2pd-data"
PID_FILE="\$BASE_DIR/i2pd.pid"
LOG_FILE="\$BASE_DIR/i2pd.log"
PROFILE_DIR="\$BASE_DIR/profile"
TB_DIR="$TB_DIR"

# Firefox binary: prefer Tor Browser for hardening, fall back to system Firefox
find_firefox() {
    [[ -x "\$TB_DIR/Browser/firefox" ]] && echo "\$TB_DIR/Browser/firefox" && return
    for fb in firefox-esr firefox; do
        command -v "\$fb" &>/dev/null && echo "\$(command -v \$fb)" && return
    done
    echo ""; return 1
}

start_i2pd() {
    # If already running (our instance), skip
    if [[ -f "\$PID_FILE" ]]; then
        local pid; pid=\$(cat "\$PID_FILE" 2>/dev/null)
        if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
            echo "[i2pfox] i2pd already running (PID \$pid)"
            return 0
        fi
    fi
    mkdir -p "\$I2PD_DATA"/{addressbook,destinations,netDb,peerProfiles,tags}

    echo "[i2pfox] Starting isolated i2pd router..."
    # Use bundled i2pd binary (system apt binary is broken on overlay/live systems)
    I2PD_BIN="\$BASE_DIR/i2pd-bin/i2pd"
    export LD_LIBRARY_PATH="\$BASE_DIR/i2pd-bin/lib:\${LD_LIBRARY_PATH:-}"
    "\$I2PD_BIN" \\
        --conf="\$I2PD_CONF" \\
        --datadir="\$I2PD_DATA" \\
        --notransit \\
        --bandwidth=L \\
        --sam.enabled=false \\
        >"\$LOG_FILE" 2>&1 &
    echo \$! > "\$PID_FILE"
    # Wait for HTTP proxy port to be ready
    local n=0
    while ! nc -z 127.0.0.1 $HTTP_PORT 2>/dev/null; do
        sleep 0.5; n=\$((n+1))
        [[ \$n -gt 20 ]] && { echo "[i2pfox] WARNING: i2pd not ready after 10s"; break; }
    done
    echo "[i2pfox] i2pd ready on :$HTTP_PORT (console: http://127.0.0.1:$CONSOLE_PORT/)"
}

launch_browser() {
    local ff; ff=\$(find_firefox) || { echo "[i2pfox] ERROR: no Firefox found"; exit 1; }
    echo "[i2pfox] Launching browser: \$ff"
    echo "[i2pfox] Profile: \$PROFILE_DIR"
    echo "[i2pfox] Router console: http://127.0.0.1:$CONSOLE_PORT/"
    echo ""
    # Open status page over HTTP (file:// pages can't fetch http:// in Tor Browser)
    "\$ff" --no-remote --profile "\$PROFILE_DIR" --class i2pfox \\
        "http://127.0.0.1:17071/" "\$@" 2>/dev/null
}

start_status_server() {
    local pid_file="\$BASE_DIR/status-server.pid"
    if [[ -f "\$pid_file" ]]; then
        local pid; pid=\$(cat "\$pid_file" 2>/dev/null)
        kill -0 "\$pid" 2>/dev/null && return 0
    fi
    python3 "\$BASE_DIR/status-server.py" &
    echo \$! > "\$pid_file"
}

main() {
    start_i2pd
    start_status_server
    launch_browser "\$@"
    # i2pd keeps running after browser closes — netDb stays warm for next launch
    # To stop i2pd: kill \$(cat \$HOME/.local/share/i2pfox/i2pd.pid)
}

main "\$@"
EOF
    chmod +x "$BIN_DIR/i2pfox"
    ok "Launcher written: $BIN_DIR/i2pfox"
}

# ── Tor Browser policies.json (forces 4get as default search) ─────────────────
write_tb_policies() {
    section "Writing Tor Browser policies + autoconfig (search + newtab + userChrome.js)"
    local dist_dir="$TB_DIR/Browser/distribution"
    local tb_root="$TB_DIR/Browser"
    mkdir -p "$dist_dir"

    # policies.json — search engine + newtab via Homepage policy
    cat > "$dist_dir/policies.json" << 'EOF'
{
  "policies": {
    "Homepage": {
      "URL": "http://127.0.0.1:17071/",
      "Locked": false,
      "StartPage": "homepage"
    },
    "SearchEngines": {
      "Default": "4get",
      "Add": [
        {
          "Name": "4get",
          "URLTemplate": "http://yorxfx5huderjzsotrgni5qy4brrtx6h73vf37tkmzemjtkya3atd7qd.onion/web?s={searchTerms}",
          "Method": "GET",
          "Alias": "4g",
          "Description": "4get — private search via Tor",
          "SuggestURLTemplate": "http://yorxfx5huderjzsotrgni5qy4brrtx6h73vf37tkmzemjtkya3atd7qd.onion/api/suggestions?query={searchTerms}"
        }
      ]
    }
  }
}
EOF

    # autoconfig pref — tells Firefox to load i2pfox.cfg
    cat > "$tb_root/defaults/pref/i2pfox-autoconfig.js" << 'EOF'
pref("general.config.filename", "i2pfox.cfg");
pref("general.config.obscure_value", 0);
EOF

    # i2pfox.cfg — loads profile/chrome/userChrome.js on every browser window open
    cat > "$tb_root/i2pfox.cfg" << 'EOF'
// i2pfox autoconfig — loads userChrome.js for network-aware tab coloring
try {
  Services.obs.addObserver(function(subject, topic) {
    try {
      var win = subject.QueryInterface(Ci.nsIInterfaceRequestor)
                       .getInterface(Ci.nsIDOMWindow);
      win.addEventListener("load", function() {
        if (win.document.documentElement.getAttribute("windowtype") !== "navigator:browser") return;
        try {
          var f = Services.dirsvc.get("ProfD", Ci.nsIFile);
          f.append("chrome");
          f.append("userChrome.js");
          if (f.exists()) {
            var loader = Cc["@mozilla.org/moz/jssubscript-loader;1"]
                           .getService(Ci.mozIJSSubScriptLoader);
            loader.loadSubScript(Services.io.newFileURI(f).spec, win);
          }
        } catch(e2) { dump("i2pfox.cfg inner: " + e2 + "\n"); }
      }, {once: true});
    } catch(e1) { dump("i2pfox.cfg outer: " + e1 + "\n"); }
  }, "domwindowopened");
} catch(e) { dump("i2pfox.cfg top: " + e + "\n"); }
EOF

    ok "TB policies + autoconfig written"
}

# ── Desktop entry ─────────────────────────────────────────────────────────────
write_desktop() {
    section "Writing desktop entry"
    local icon="$ASSETS_DIR/fox.png"
    [[ -f "$icon" ]] || icon="$ASSETS_DIR/fox.svg"
    cat > "$APP_DIR/i2pfox.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=I2Pfox
GenericName=I2P Privacy Browser
Comment=Browse the I2P network privately — based on Tor Browser
Exec=$BIN_DIR/i2pfox %u
Icon=$icon
Terminal=false
Categories=Network;WebBrowser;Security;
Keywords=i2p;privacy;anonymous;browser;
StartupWMClass=i2pfox
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF
    chmod +x "$APP_DIR/i2pfox.desktop"
    ok "Desktop entry written"
}

# ── PATH reminder ─────────────────────────────────────────────────────────────
ensure_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not in your PATH"
        info "Add this to ~/.bashrc:  export PATH=\"\$PATH:$BIN_DIR\""
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${C}"
    echo "  ██╗ ██████╗ ██████╗ ███████╗ ██████╗ ██╗  ██╗"
    echo "  ██║ ╚════██╗██╔══██╗██╔════╝██╔═══██╗╚██╗██╔╝"
    echo "  ██║  █████╔╝██████╔╝█████╗  ██║   ██║ ╚███╔╝ "
    echo "  ██║ ██╔═══╝ ██╔═══╝ ██╔══╝  ██║   ██║ ██╔██╗ "
    echo "  ██║ ███████╗██║     ██║     ╚██████╔╝██╔╝ ██╗"
    echo "  ╚═╝ ╚══════╝╚═╝     ╚═╝      ╚═════╝ ╚═╝  ╚═╝"
    echo -e "${N}  The I2P Privacy Browser — based on Tor Browser"
    echo -e "  v0.1.0-alpha"
    echo ""

    TB_DIR=""
    find_tor_browser "$@"
    check_deps
    create_dirs
    install_i2pd_bin
    write_i2pd_conf
    write_addressbook
    write_pac
    write_userjs
    write_userchrome
    write_userchromejs
    write_usercontent
    write_searchplugins
    write_extension
    write_network_extension
    write_bookmarks
    write_home
    write_status_server
    write_fox_svg
    write_launcher
    write_tb_policies
    write_desktop
    ensure_path

    echo ""
    echo -e "${G}════════════════════════════════════════${N}"
    echo -e "${G}  I2Pfox installed successfully!${N}"
    echo -e "${G}════════════════════════════════════════${N}"
    echo ""
    echo "  Launch:        i2pfox"
    echo "  Or:            $BIN_DIR/i2pfox"
    echo ""
    echo "  Router console:  http://127.0.0.1:$CONSOLE_PORT/"
    echo "  HTTP proxy:      127.0.0.1:$HTTP_PORT"
    echo "  Address book:    $I2PD_DATA/addressbook/addresses.csv"
    echo "  Extension:       $EXT_DIR/${EXT_ID}.xpi"
    echo ""
    echo "  All config files are plain text — fully auditable."
    echo ""
    info "On first launch, i2pd needs ~2 min to bootstrap and join the network."
    info "Unknown .i2p addresses are auto-resolved via jump services."
}

main "$@"
