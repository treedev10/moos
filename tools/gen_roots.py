#!/usr/bin/env python3
"""
Build src/roots.bin: the root certificates MOOS trusts for HTTPS.

    python tools/gen_roots.py

Takes a fixed list of widely used RSA root CAs from this computer's trust
store (only self-signed, RSA, in-date roots) and writes them as
    [u16 big-endian length][DER certificate] ... [0x0000]
MOOS checks a server's certificate chain against these (see src/x509.asm).
ISRG Root X1 (Let's Encrypt) is the one GitHub's raw-content server chains to.
"""
import datetime
import os
import ssl

from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import rsa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "roots.bin")

WANTED = [
    "ISRG Root X1",                                  # Let's Encrypt (GitHub raw)
    "DigiCert Global Root CA",
    "DigiCert Global Root G2",
    "USERTrust RSA Certification Authority",         # Sectigo
    "Amazon Root CA 1",
    "GTS Root R1",                                   # Google Trust Services
    "GlobalSign Root CA",
    "GlobalSign",                                    # GlobalSign R3 / R6 (RSA)
    "Microsoft RSA Root Certificate Authority 2017",
    "Go Daddy Root Certificate Authority - G2",
    "Starfield Root Certificate Authority - G2",
    "Certum Trusted Network CA",
    "IdenTrust Commercial Root CA 1",
]


def cn_of(cert):
    attrs = cert.subject.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)
    return attrs[0].value if attrs else ""


def main():
    now = datetime.datetime.now(datetime.timezone.utc)
    chosen = []
    seen = set()
    for der in ssl.create_default_context().get_ca_certs(binary_form=True):
        cert = x509.load_der_x509_certificate(der)
        if cn_of(cert) not in WANTED or cert.subject != cert.issuer:
            continue
        if not isinstance(cert.public_key(), rsa.RSAPublicKey):
            continue
        if cert.not_valid_after_utc < now or der in seen:
            continue
        seen.add(der)
        chosen.append((cn_of(cert), der))
    assert any(n == "ISRG Root X1" for n, _ in chosen), "ISRG Root X1 not found"
    out = b"".join(len(d).to_bytes(2, "big") + d for _, d in chosen) + b"\0\0"
    open(OUT, "wb").write(out)
    for name, der in chosen:
        print("  %-48s %5d bytes" % (name, len(der)))
    print("wrote %s: %d roots, %d bytes" % (os.path.relpath(OUT, ROOT), len(chosen), len(out)))


if __name__ == "__main__":
    main()
