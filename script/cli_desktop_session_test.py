"""Exercise the production desktop query with independent system API answers, without logging out."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
INTERPOSE = r'''
#include <Security/AuthSession.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static OSStatus caller(SecuritySessionId requested, SecuritySessionId *session, SessionAttributeBits *attributes) {
    const char *mode = getenv("DESKTOP_FIXTURE");
    *session = 123;
    *attributes = !strcmp(mode, "switched") ? sessionHasGraphicAccess : 0;
    return !strncmp(mode, "security-error-", 15) ? errSessionInvalidId : errSecSuccess;
}
static CFStringRef console(SCDynamicStoreRef store, uid_t *uid, gid_t *gid) {
    const char *mode = getenv("DESKTOP_FIXTURE");
    if (!strcmp(mode, "none") || !strcmp(mode, "nokey") || !strcmp(mode, "error") ||
        !strcmp(mode, "security-error-none")) return NULL;
    *uid = getuid() + ((!strcmp(mode, "other") || !strcmp(mode, "switched")) ? 1 : 0); *gid = getgid();
    return CFRetain(!strcmp(mode, "loginwindow") ? CFSTR("loginwindow") : CFSTR("console-user"));
}
static int status(void) {
    const char *mode = getenv("DESKTOP_FIXTURE");
    return !strcmp(mode, "error") ? kSCStatusFailed : (!strcmp(mode, "nokey") ? kSCStatusNoKey : kSCStatusOK);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *replacement; const void *original; } replacements[] = {
    {caller, SessionGetInfo}, {console, SCDynamicStoreCopyConsoleUser}, {status, SCError}
};
'''

with tempfile.TemporaryDirectory(prefix='desktop-') as temporary:
    root = Path(temporary)
    (root / 'session.c').write_text(INTERPOSE)
    (root / 'main.swift').write_text('import Foundation\nimport Darwin\n'
        'do { print(try CLIDesktopSession().hasGraphicAccess() ? "desktop" : "none") } '
        'catch { print(error.localizedDescription); exit(2) }\n')
    subprocess.run(['xcrun', 'clang', '-dynamiclib', str(root / 'session.c'), '-framework', 'Security',
                    '-framework', 'SystemConfiguration', '-framework', 'CoreFoundation', '-o', str(root / 'session.dylib')], check=True, timeout=30)
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Pensieve/Services/CLIDesktopSession.swift'),
                    str(root / 'main.swift'), '-o', str(root / 'query')], check=True, timeout=30)
    for mode, status, output in [('current', 0, 'desktop'), ('switched', 0, 'desktop'), ('other', 0, 'none'),
                                  ('loginwindow', 0, 'none'), ('none', 0, 'none'),
                                  ('nokey', 0, 'none'), ('error', 2, None),
                                  ('security-error-current', 0, 'desktop'), ('security-error-none', 2, None)]:
        result = subprocess.run([str(root / 'query')], text=True, capture_output=True,
            env=dict(os.environ, DESKTOP_FIXTURE=mode, DYLD_INSERT_LIBRARIES=str(root / 'session.dylib')), timeout=10)
        assert result.returncode == status, (mode, result)
        if output:
            assert result.stdout.strip() == output, (mode, result.stdout, result.stderr)
        print(mode, result.returncode, result.stdout.strip())
