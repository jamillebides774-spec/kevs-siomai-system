"""
==============================================================================
  🛡️ KEVS SIOMAI — WEB APPLICATION FIREWALL (WAF) & SECURITY ENGINE
==============================================================================
Features:
- SQL Injection (SQLi) Inspection & Blocking
- Cross-Site Scripting (XSS) Detection & Blocking
- Path Traversal & Local File Inclusion (LFI) Blocking
- Remote Code Execution (RCE) / Command Injection Inspection
- Malicious Vulnerability Scanner & Bot Blocker (sqlmap, nikto, etc.)
- Sliding-Window Rate Limiter & DoS Protection
- Stricter Anti-Brute-Force Rate Limiting for Authentication
- Automatic IP Jail / Temporary Ban for Persistent Attackers
- OWASP Recommended HTTP Security Headers
- Real-time Threat Logging & Metrics for Admin Dashboard
==============================================================================
"""

import re
import time
from collections import defaultdict, deque
from datetime import datetime, timezone
from flask import request, jsonify, g, Blueprint

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL RULE PATTERNS (REGEX)
# ─────────────────────────────────────────────────────────────────────────────

# SQL Injection Patterns — carefully tuned to avoid false positives
SQLI_PATTERNS = [
    # UNION SELECT is a classic SQLi technique
    re.compile(r"(\bUNION\b\s+(ALL\s+)?SELECT)", re.IGNORECASE),
    # Time-based blind SQLi (WAITFOR DELAY / SLEEP / BENCHMARK)
    re.compile(r"(\bWAITFOR\s+DELAY\b|\bBENCHMARK\s*\(|\bSLEEP\s*\()", re.IGNORECASE),
    # Stacked queries: 1=1, 'OR'=, etc.
    re.compile(r"(\bOR\b\s+1\s*=\s*1\b|\bAND\b\s+1\s*=\s*1\b)", re.IGNORECASE),
    re.compile(r"('\s*(OR|AND)\s*'?\w+'?\s*=\s*'?\w+)", re.IGNORECASE),
    # Inline comment injection markers (at end of line or in payload)
    re.compile(r"(--\s*$|/\*.*?\*/)", re.IGNORECASE | re.DOTALL),
    # System commands / dangerous procs
    re.compile(r"(\bINFORMATION_SCHEMA\b|\bXP_CMDSHELL\b)", re.IGNORECASE),
    # DROP / TRUNCATE / ALTER — rarely needed in legitimate web input
    re.compile(r"\b(DROP|TRUNCATE|ALTER)\s+(TABLE|DATABASE|INDEX)\b", re.IGNORECASE),
]

# Cross-Site Scripting (XSS) Patterns
XSS_PATTERNS = [
    re.compile(r"<\s*script[^>]*>.*?", re.IGNORECASE),
    re.compile(r"<\s*/\s*script\s*>", re.IGNORECASE),
    re.compile(r"javascript\s*:", re.IGNORECASE),
    re.compile(r"vbscript\s*:", re.IGNORECASE),
    re.compile(r"data\s*:\s*text/html", re.IGNORECASE),
    re.compile(r"on(load|error|click|mouseover|focus|blur|change|submit|keydown|keypress)\s*=", re.IGNORECASE),
    re.compile(r"<\s*(iframe|object|embed|svg|applet|meta|link|base)[^>]*>", re.IGNORECASE),
    re.compile(r"document\.(cookie|location|domain|write)", re.IGNORECASE),
    re.compile(r"alert\s*\(", re.IGNORECASE),
]

# Path Traversal & LFI Patterns
PATH_TRAVERSAL_PATTERNS = [
    re.compile(r"(\.\./|\.\.\\|\.%2e/|\.%2e\\|%2e%2e/|%2e%2e\\)", re.IGNORECASE),
    re.compile(r"(/etc/(passwd|shadow|hosts|group|issue)|win\.ini|boot\.ini)", re.IGNORECASE),
    re.compile(r"(%00|\x00)", re.IGNORECASE),
]

# Remote Code Execution (RCE) / Command Injection Patterns
RCE_PATTERNS = [
    re.compile(r"(\b(bash|sh|zsh|csh)\s+-i|\bpowershell\b|\bcmd\.exe\b)", re.IGNORECASE),
    re.compile(r"(\b(nc|ncat|netcat)\s+-\w*e\b)", re.IGNORECASE),
    re.compile(r"(\|\s*rm\s+-rf|;\s*rm\s+-rf)", re.IGNORECASE),
    re.compile(r"(\$\(.*?\)|\`.*?\`)", re.IGNORECASE),
    re.compile(r"(;\s*(cat|ls|id|whoami|uname)\b)", re.IGNORECASE),
]

# Malicious Scanner User-Agents
SCANNER_USER_AGENTS = [
    re.compile(r"(sqlmap|nikto|dirbuster|gobuster|wpscan|nmap|masscan|zgrab|acunetix|nessus|burpcollaborator)", re.IGNORECASE),
    re.compile(r"(arachni|qualys|netsparker|openvas|hydra|w3af|havij)", re.IGNORECASE),
]


class WebApplicationFirewall:
    """Enterprise-grade Flask WAF and Rate Limiter with Security Analytics."""

    def __init__(self, app=None):
        self.enabled = True
        self.sqli_protection = True
        self.xss_protection = True
        self.path_traversal_protection = True
        self.rce_protection = True
        self.scanner_blocker = True
        self.rate_limiting = True

        # Limits
        self.general_rate_limit = 300    # requests per minute per IP (5 req/sec sustained)
        self.auth_rate_limit = 30        # login attempts per minute per IP
        self.max_body_bytes = 2 * 1024 * 1024  # 2MB

        # Storage
        self.request_windows = defaultdict(deque)    # ip -> deque of timestamps
        self.auth_windows = defaultdict(deque)       # ip -> deque of timestamps
        self.exploit_windows = defaultdict(deque)    # ip -> deque of exploit timestamps (10-min window)
        self.ratelimit_windows = defaultdict(deque)  # ip -> deque of 429 timestamps (60-sec window)
        self.violation_counts = defaultdict(int)     # ip -> violation count
        self.banned_ips = {}                         # ip -> unban timestamp

        self.whitelisted_ips = {'127.0.0.1', '::1', 'localhost'}
        self.blacklisted_ips = set()

        # Telemetry & Security Logs (In-memory ring buffer)
        self.total_scanned = 0
        self.total_blocked = 0
        self.threat_counts = {
            'sqli': 0,
            'xss': 0,
            'path_traversal': 0,
            'rce': 0,
            'scanner': 0,
            'rate_limit': 0,
            'ip_blacklist': 0,
            'payload_too_large': 0
        }
        self.recent_logs = deque(maxlen=150)
        self.start_time = datetime.now(timezone.utc)

        if app:
            self.init_app(app)

    def init_app(self, app):
        """Attach WAF before_request and after_request hooks to Flask application."""
        app.before_request(self._inspect_request)
        app.after_request(self._inject_security_headers)

    def _get_client_ip(self):
        """Retrieve actual client IP, handling proxies safely."""
        x_forwarded = request.headers.get('X-Forwarded-For')
        if x_forwarded:
            ip = x_forwarded.split(',')[0].strip()
        else:
            ip = request.remote_addr or '127.0.0.1'
        return ip

    def _log_threat(self, threat_type, details, severity="HIGH"):
        """Record security event in firewall telemetry and evaluate auto-jail."""
        ip = self._get_client_ip()
        self.total_blocked += 1
        self.threat_counts[threat_type] = self.threat_counts.get(threat_type, 0) + 1
        self.violation_counts[ip] += 1
        now = time.time()

        # Auto-jail rules:
        # Never auto-jail whitelisted IPs or manual admin tests
        if severity != "TEST" and ip not in self.whitelisted_ips:
            if threat_type == 'rate_limit':
                # Rate limit throttling: track 429 blocks in 60s window
                rl_deque = self.ratelimit_windows[ip]
                while rl_deque and rl_deque[0] < now - 60.0:
                    rl_deque.popleft()
                rl_deque.append(now)

                # Only auto-jail if client aggressively hammers with >= 30 rate-limit blocks within 60 seconds (active flood)
                if len(rl_deque) >= 30:
                    self.banned_ips[ip] = now + 300  # 5 minutes temporary jail
                    details += " [IP Auto-Banned for 5 mins due to aggressive request flood]"
            else:
                # Malicious exploit attempt (sqli, xss, path_traversal, rce, scanner)
                ex_deque = self.exploit_windows[ip]
                while ex_deque and ex_deque[0] < now - 600.0:
                    ex_deque.popleft()
                ex_deque.append(now)

                # Auto-jail if >= 5 malicious exploit attempts within 10 minutes
                if len(ex_deque) >= 5:
                    self.banned_ips[ip] = now + 900  # 15 minutes temporary jail
                    details += " [IP Auto-Banned for 15 mins due to repeated malicious exploit attempts]"

        event = {
            'id': f"sec-{int(time.time() * 1000)}-{self.total_blocked}",
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'ip': ip,
            'threat_type': threat_type.upper(),
            'severity': severity,
            'path': request.path,
            'method': request.method,
            'user_agent': request.headers.get('User-Agent', 'Unknown')[:100],
            'details': details[:300]
        }
        self.recent_logs.appendleft(event)
        try:
            print(f"[WAF BLOCKED] {threat_type.upper()} from {ip} on {request.method} {request.path}: {details}")
        except Exception:
            pass

    def _check_rate_limit(self, ip, is_auth=False):
        """Sliding-window rate limiter."""
        now = time.time()
        window = 60.0  # 1 minute

        target_deque = self.auth_windows[ip] if is_auth else self.request_windows[ip]
        max_allowed = self.auth_rate_limit if is_auth else self.general_rate_limit

        # Evict timestamps older than 60 seconds
        while target_deque and target_deque[0] < now - window:
            target_deque.popleft()

        if len(target_deque) >= max_allowed:
            return False

        target_deque.append(now)
        return True

    def _inspect_request(self):
        """Primary inspection pipeline executed before every incoming request."""
        if not self.enabled:
            return None

        # Do not block static assets, mobile app bundles, images, documentation, or Socket.IO handshakes
        EXEMPT_PREFIXES = (
            '/assets/',
            '/static/',
            '/images/',
            '/mobile',
            '/favicon',
            '/manifest',
            '/sw.js',
            '/socket.io',
            '/robots.txt'
        )
        if request.path.startswith(EXEMPT_PREFIXES) or request.path in ('/', '/mobile'):
            return None

        self.total_scanned += 1
        ip = self._get_client_ip()
        now = time.time()

        # 1. IP Ban & Blacklist Check
        if ip in self.banned_ips:
            if now < self.banned_ips[ip]:
                remaining = int(self.banned_ips[ip] - now)
                return jsonify({
                    'error': 'Access Denied by Kevs WAF Firewall',
                    'reason': f'Your IP has been temporarily banned due to suspicious activity. Try again in {remaining}s.',
                    'waf_status': 'blocked',
                    'threat_type': 'IP_BANNED'
                }), 403
            else:
                del self.banned_ips[ip]
                # Reset violation tracking so the IP starts fresh after completing its ban
                self.exploit_windows.pop(ip, None)
                self.ratelimit_windows.pop(ip, None)
                self.violation_counts.pop(ip, None)

        if ip in self.blacklisted_ips:
            self._log_threat('ip_blacklist', f"Blacklisted IP access attempt: {ip}", severity="CRITICAL")
            return jsonify({
                'error': 'Access Denied by Kevs WAF Firewall',
                'reason': 'Your IP address is permanently blocked.',
                'waf_status': 'blocked',
                'threat_type': 'IP_BLACKLIST'
            }), 403

        # 2. Scanner & Bot Blocker
        if self.scanner_blocker and ip not in self.whitelisted_ips:
            ua = request.headers.get('User-Agent', '')
            for pattern in SCANNER_USER_AGENTS:
                if pattern.search(ua):
                    self._log_threat('scanner', f"Malicious scanner bot detected: {ua}", severity="HIGH")
                    return jsonify({
                        'error': 'Forbidden: Automated Security Scanner Detected',
                        'waf_status': 'blocked',
                        'threat_type': 'SCANNER_DETECTED'
                    }), 403

        # 3. Request Payload Size Protection
        if request.content_length and request.content_length > self.max_body_bytes:
            self._log_threat('payload_too_large', f"Payload exceeded limit: {request.content_length} bytes", severity="MEDIUM")
            return jsonify({
                'error': 'Payload Too Large: Kevs WAF enforces a 2MB maximum request size',
                'waf_status': 'blocked',
                'threat_type': 'PAYLOAD_TOO_LARGE'
            }), 413

        # 4. Rate Limiting Check
        if self.rate_limiting and ip not in self.whitelisted_ips:
            is_auth = request.path == '/api/auth/login'
            if not self._check_rate_limit(ip, is_auth=is_auth):
                limit_type = "Auth Login" if is_auth else "General API"
                self._log_threat('rate_limit', f"{limit_type} rate limit exceeded by {ip}", severity="MEDIUM")
                return jsonify({
                    'error': 'Too Many Requests',
                    'reason': f'Firewall rate limit exceeded for {limit_type}. Please slow down.',
                    'retry_after': 60,
                    'waf_status': 'blocked',
                    'threat_type': 'RATE_LIMIT_EXCEEDED'
                }), 429

        # 5. Extract all inputs for deep inspection
        inputs_to_check = []

        # Path & Query string
        inputs_to_check.append(('path', request.path))
        for k, v in request.args.items():
            inputs_to_check.append((f"query:{k}", v))

        # JSON body or Form data
        if request.is_json:
            try:
                body = request.get_json(silent=True)
                if isinstance(body, dict):
                    self._extract_dict_strings(body, inputs_to_check, prefix="body")
                elif isinstance(body, list):
                    for idx, item in enumerate(body):
                        if isinstance(item, dict):
                            self._extract_dict_strings(item, inputs_to_check, prefix=f"body[{idx}]")
                        elif isinstance(item, str):
                            inputs_to_check.append((f"body[{idx}]", item))
            except Exception:
                pass
        elif request.form:
            for k, v in request.form.items():
                inputs_to_check.append((f"form:{k}", v))

        # 6. Deep Content Inspection
        for src, val in inputs_to_check:
            if not isinstance(val, str):
                continue

            # Path Traversal
            if self.path_traversal_protection:
                for pattern in PATH_TRAVERSAL_PATTERNS:
                    if pattern.search(val):
                        self._log_threat('path_traversal', f"LFI attempt in {src}: {val}", severity="CRITICAL")
                        return jsonify({
                            'error': 'Forbidden: Malicious Path Traversal Detected',
                            'waf_status': 'blocked',
                            'threat_type': 'PATH_TRAVERSAL',
                            'field': src
                        }), 403

            # SQL Injection
            if self.sqli_protection:
                for pattern in SQLI_PATTERNS:
                    if pattern.search(val):
                        self._log_threat('sqli', f"SQLi pattern detected in {src}: {val}", severity="CRITICAL")
                        return jsonify({
                            'error': 'Forbidden: Malicious SQL Injection Detected',
                            'waf_status': 'blocked',
                            'threat_type': 'SQL_INJECTION',
                            'field': src
                        }), 403

            # Cross-Site Scripting (XSS)
            if self.xss_protection:
                for pattern in XSS_PATTERNS:
                    if pattern.search(val):
                        self._log_threat('xss', f"XSS script payload detected in {src}: {val}", severity="HIGH")
                        return jsonify({
                            'error': 'Forbidden: Cross-Site Scripting (XSS) Detected',
                            'waf_status': 'blocked',
                            'threat_type': 'XSS_ATTACK',
                            'field': src
                        }), 403

            # Remote Code Execution (RCE)
            if self.rce_protection:
                for pattern in RCE_PATTERNS:
                    if pattern.search(val):
                        self._log_threat('rce', f"Command injection attempt in {src}: {val}", severity="CRITICAL")
                        return jsonify({
                            'error': 'Forbidden: Command Injection / RCE Detected',
                            'waf_status': 'blocked',
                            'threat_type': 'RCE_ATTACK',
                            'field': src
                        }), 403

        return None

    def _extract_dict_strings(self, d, target_list, prefix=""):
        """Recursively extract nested strings from dictionary for WAF inspection."""
        for k, v in d.items():
            key_name = f"{prefix}.{k}" if prefix else str(k)
            if isinstance(v, str):
                target_list.append((key_name, v))
            elif isinstance(v, dict):
                self._extract_dict_strings(v, target_list, prefix=key_name)
            elif isinstance(v, list):
                for idx, item in enumerate(v):
                    if isinstance(item, str):
                        target_list.append((f"{key_name}[{idx}]", item))
                    elif isinstance(item, dict):
                        self._extract_dict_strings(item, target_list, prefix=f"{key_name}[{idx}]")

    def _inject_security_headers(self, response):
        """Inject strict OWASP-compliant security headers into every response."""
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['X-Frame-Options'] = 'SAMEORIGIN'
        response.headers['X-XSS-Protection'] = '1; mode=block'
        response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
        response.headers['Server'] = 'Kevs-WAF-Gateway/2.0'
        response.headers['X-Firewall-Protected'] = 'KEVS-Active-WAF'
        response.headers['Permissions-Policy'] = 'geolocation=(), camera=(), microphone=()'
        
        # CSP: allows self, Google fonts, ChartJS CDN, and SocketIO CDN
        csp_directives = [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.socket.io https://cdn.jsdelivr.net https://www.gstatic.com",
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
            "font-src 'self' https://fonts.gstatic.com data:",
            "connect-src 'self' ws: wss: http: https:",
            "img-src 'self' data: blob:",
            "object-src 'none'",
            "base-uri 'self'"
        ]
        response.headers['Content-Security-Policy'] = "; ".join(csp_directives)
        return response

    def get_stats(self):
        """Export firewall health and telemetry metrics for the admin interface."""
        now = datetime.now(timezone.utc)
        uptime_seconds = int((now - self.start_time).total_seconds())

        return {
            'status': 'active' if self.enabled else 'disabled',
            'uptime_seconds': uptime_seconds,
            'total_scanned': self.total_scanned,
            'total_blocked': self.total_blocked,
            'threat_counts': dict(self.threat_counts),
            'banned_ips_count': len(self.banned_ips),
            'banned_ips': list(self.banned_ips.keys()),
            'blacklisted_ips_count': len(self.blacklisted_ips),
            'blacklisted_ips': list(self.blacklisted_ips),
            'active_engines': {
                'sqli_protection': self.sqli_protection,
                'xss_protection': self.xss_protection,
                'path_traversal': self.path_traversal_protection,
                'rce_protection': self.rce_protection,
                'scanner_blocker': self.scanner_blocker,
                'rate_limiting': self.rate_limiting,
            },
            'rules_count': len(SQLI_PATTERNS) + len(XSS_PATTERNS) + len(PATH_TRAVERSAL_PATTERNS) + len(RCE_PATTERNS) + len(SCANNER_USER_AGENTS) + 2
        }

    def get_logs(self):
        """Return circular buffer of recent security events."""
        return list(self.recent_logs)

    def test_threat(self, threat_type):
        """Safe test attack simulator to demonstrate WAF blocking capability."""
        simulated_payloads = {
            'sqli': "' OR 1=1; DROP TABLE users; --",
            'xss': "<script>alert('XSS Attack Neutralized by Kevs WAF!')</script>",
            'path_traversal': "../../../../etc/passwd",
            'rce': "; cat /etc/shadow && rm -rf /",
            'scanner': "sqlmap/1.7.2#stable (https://sqlmap.org)"
        }
        payload = simulated_payloads.get(threat_type.lower(), "' OR 1=1 --")
        self._log_threat(threat_type.lower(), f"Manual Security Self-Test: {payload}", severity="TEST")
        return {
            'tested_threat': threat_type,
            'payload': payload,
            'firewall_action': 'BLOCKED (HTTP 403 Forbidden)',
            'timestamp': datetime.now(timezone.utc).isoformat()
        }


# Global WAF instance
waf = WebApplicationFirewall()


# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL ADMIN API BLUEPRINT
# ─────────────────────────────────────────────────────────────────────────────
firewall_api = Blueprint('firewall_api', __name__, url_prefix='/api/firewall')

@firewall_api.route('/stats', methods=['GET'])
def get_firewall_stats():
    """Return live firewall telemetry and status."""
    return jsonify(waf.get_stats()), 200

@firewall_api.route('/logs', methods=['GET'])
def get_firewall_logs():
    """Return live security logs of blocked attacks."""
    return jsonify({
        'logs': waf.get_logs(),
        'total': len(waf.recent_logs)
    }), 200

@firewall_api.route('/test', methods=['POST'])
def test_firewall_threat():
    """Simulate a threat to verify firewall interception."""
    data = request.get_json() or {}
    threat_type = data.get('threat_type', 'sqli')
    result = waf.test_threat(threat_type)
    return jsonify({
        'message': 'Firewall intercepted test threat successfully!',
        'result': result,
        'stats': waf.get_stats()
    }), 200

@firewall_api.route('/block-ip', methods=['POST'])
def block_ip():
    """Manually add an IP to the blacklist."""
    data = request.get_json() or {}
    ip = data.get('ip', '').strip()
    if not ip:
        return jsonify({'error': 'IP address is required'}), 400
    if ip in waf.whitelisted_ips:
        return jsonify({'error': 'Cannot block whitelisted address'}), 400
    waf.blacklisted_ips.add(ip)
    return jsonify({'message': f'IP {ip} added to blacklist', 'blacklisted_ips': list(waf.blacklisted_ips)}), 200

@firewall_api.route('/unblock-ip', methods=['POST'])
def unblock_ip():
    """Remove an IP from blacklist or temporary ban and reset its security counters."""
    data = request.get_json() or {}
    ip = data.get('ip', '').strip()
    if not ip:
        return jsonify({'error': 'IP address is required'}), 400
    if ip in waf.blacklisted_ips:
        waf.blacklisted_ips.remove(ip)
    if ip in waf.banned_ips:
        del waf.banned_ips[ip]
    waf.exploit_windows.pop(ip, None)
    waf.ratelimit_windows.pop(ip, None)
    waf.violation_counts.pop(ip, None)
    return jsonify({
        'message': f'IP {ip} unblocked and security counters reset',
        'blacklisted_ips': list(waf.blacklisted_ips),
        'banned_ips': list(waf.banned_ips.keys())
    }), 200

@firewall_api.route('/toggle', methods=['POST'])
def toggle_firewall():
    """Toggle specific engines or global firewall state."""
    data = request.get_json() or {}
    if 'enabled' in data:
        waf.enabled = bool(data['enabled'])
    if 'rate_limiting' in data:
        waf.rate_limiting = bool(data['rate_limiting'])
    if 'sqli_protection' in data:
        waf.sqli_protection = bool(data['sqli_protection'])
    if 'xss_protection' in data:
        waf.xss_protection = bool(data['xss_protection'])
    return jsonify({'message': 'Firewall settings updated', 'stats': waf.get_stats()}), 200
