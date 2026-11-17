//! The keys and TLS that keep sync between devices private.
//!
//! Each device has its own key and a certificate for it, made once and kept in the data folder.
//! Paired devices know each other by the fingerprint of that certificate: sync runs over TLS
//! 1.3 where both sides show their certificate, a client only goes on with the device whose
//! fingerprint it paired with, and a server only answers devices of its circle. What travels
//! is encrypted, a session cannot be taken over, and a device taken out of the circle has
//! nothing left that opens it. Before devices are paired, the certificates are only seen, not
//! checked; pairing then ties the code to the fingerprints each side saw (`listenook_core::sync::Pake`).

use std::{
    io,
    net::TcpStream,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use listenook_core::sync::{hex, unhex};
use rustls::{
    DigitallySignedStruct, DistinguishedName, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{CryptoProvider, WebPkiSupportedAlgorithms},
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::state::persist;

/// This device's key and the certificate that names it.
pub(crate) struct Identity {
    certificate: CertificateDer<'static>,
    key: Vec<u8>,
    /// The certificate's fingerprint, by which the other devices know this one.
    pub(crate) fingerprint: String,
    server: Arc<rustls::ServerConfig>,
}

#[derive(Serialize, Deserialize)]
struct Saved {
    certificate: String,
    key: String,
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// The fingerprint by which a certificate is known: the SHA-256 of its bytes.
pub(crate) fn fingerprint(certificate: &[u8]) -> String {
    hex(&Sha256::digest(certificate))
}

impl Identity {
    /// This device's identity, read from `root`, or made and saved there the first time.
    pub(crate) fn of(root: &Path) -> io::Result<Arc<Identity>> {
        let path = root.join("sync-identity.json");
        let saved = match persist::read_json::<Saved>(&path) {
            Some(saved) => saved,
            None if path.exists() => return Err(io::Error::other("the sync identity can't be read")),
            None => {
                let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).map_err(io::Error::other)?;
                let certificate = rcgen::CertificateParams::new(vec!["listenook".to_owned()])
                    .and_then(|params| params.self_signed(&key))
                    .map_err(io::Error::other)?;
                let saved = Saved { certificate: hex(certificate.der()), key: hex(&key.serialize_der()) };
                let bytes = serde_json::to_vec(&saved).map_err(io::Error::other)?;
                persist::write_durably(&path, &bytes, true)?;
                saved
            }
        };
        let broken = || io::Error::other("the sync identity is damaged");
        let certificate = CertificateDer::from(unhex(&saved.certificate).ok_or_else(broken)?);
        let key = unhex(&saved.key).ok_or_else(broken)?;
        let server = rustls::ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(io::Error::other)?
            .with_client_cert_verifier(Arc::new(AnyClient(provider().signature_verification_algorithms)))
            .with_single_cert(vec![certificate.clone()], private(&key))
            .map_err(io::Error::other)?;
        Ok(Arc::new(Identity { fingerprint: fingerprint(&certificate), certificate, key, server: Arc::new(server) }))
    }

    /// An HTTP client that shows this device's certificate and goes on only with a server whose
    /// fingerprint is `expected`, or with any server when it is `None`; `seen` gets the
    /// fingerprint of the server it reached. It waits `read` for answers.
    pub(crate) fn agent(
        &self,
        expected: Option<&str>,
        seen: Option<Arc<Mutex<String>>>,
        read: Duration,
    ) -> ureq::Agent {
        self.builder(expected, seen).timeout_connect(Duration::from_secs(4)).timeout_read(read).build()
    }

    /// The client of `agent`, to set its own times on.
    pub(crate) fn builder(&self, expected: Option<&str>, seen: Option<Arc<Mutex<String>>>) -> ureq::AgentBuilder {
        let verifier = Pinned {
            expected: expected.map(str::to_owned),
            seen,
            algorithms: provider().signature_verification_algorithms,
        };
        let config = rustls::ClientConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .expect("TLS 1.3 is supported")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_client_auth_cert(vec![self.certificate.clone()], private(&self.key))
            .expect("the identity's own key fits its certificate");
        ureq::AgentBuilder::new().tls_config(Arc::new(config)).timeout_write(Duration::from_secs(60))
    }

    /// Takes a connection made to this device through TLS: the stream, and the fingerprint of
    /// the certificate the other side showed.
    pub(crate) fn accept(&self, tcp: TcpStream) -> io::Result<(Wire, String)> {
        let connection = rustls::ServerConnection::new(self.server.clone()).map_err(io::Error::other)?;
        let mut wire = rustls::StreamOwned::new(connection, tcp);
        while wire.conn.is_handshaking() {
            wire.conn.complete_io(&mut wire.sock)?;
        }
        let shown = wire.conn.peer_certificates().and_then(|chain| chain.first()).map(|first| fingerprint(first));
        let shown = shown.ok_or_else(|| io::Error::other("no certificate was shown"))?;
        Ok((wire, shown))
    }
}

fn private(key: &[u8]) -> PrivateKeyDer<'static> {
    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.to_vec()))
}

/// A connection made to this device, over TLS.
pub(crate) type Wire = rustls::StreamOwned<rustls::ServerConnection, TcpStream>;

/// Checks the server's certificate by its fingerprint, not by a certificate authority: the
/// devices made their own. The signatures are checked all the same, so the server has to hold
/// the key of the certificate it shows.
#[derive(Debug)]
struct Pinned {
    expected: Option<String>,
    seen: Option<Arc<Mutex<String>>>,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let shown = fingerprint(end_entity);
        if self.expected.as_ref().is_some_and(|expected| *expected != shown) {
            return Err(rustls::Error::General("not the paired device".into()));
        }
        if let Some(seen) = &self.seen {
            *seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = shown;
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signed: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, certificate, signed, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signed: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, certificate, signed, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// Asks every client for a certificate and checks that it holds the key, whatever certificate
/// it is: which devices may do what is decided by the fingerprint, request by request.
#[derive(Debug)]
struct AnyClient(WebPkiSupportedAlgorithms);

impl ClientCertVerifier for AnyClient {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signed: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, certificate, signed, &self.0)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signed: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, certificate, signed, &self.0)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use std::{io::Read, net::TcpListener};

    use super::*;

    fn root(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("listenook-secure-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    /// Answers one request over TLS: the fingerprint the client showed, and what it sent.
    fn answer_once(server: Arc<Identity>) -> (u16, std::thread::JoinHandle<Option<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            let (mut wire, shown) = server.accept(tcp).ok()?;
            let mut head = [0_u8; 1024];
            let _ = wire.read(&mut head);
            use std::io::Write;
            let _ = wire.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
            let _ = wire.flush();
            wire.conn.send_close_notify();
            let _ = wire.conn.complete_io(&mut wire.sock);
            Some(shown)
        });
        (port, handle)
    }

    #[test]
    fn devices_reach_only_the_device_they_paired_with_and_show_who_they_are() {
        let (here, there) = (Identity::of(&root("here")).unwrap(), Identity::of(&root("there")).unwrap());
        assert_ne!(here.fingerprint, there.fingerprint);
        assert_eq!(Identity::of(&root_kept("here")).unwrap().fingerprint, here.fingerprint, "kept once made");

        let (port, served) = answer_once(there.clone());
        let seen = Arc::new(Mutex::new(String::new()));
        let agent = here.agent(Some(&there.fingerprint), Some(seen.clone()), Duration::from_secs(5));
        let body = agent.get(&format!("https://127.0.0.1:{port}/listenook/info")).call().unwrap().into_string();
        assert_eq!(body.unwrap(), "ok");
        assert_eq!(*seen.lock().unwrap(), there.fingerprint);
        assert_eq!(served.join().unwrap(), Some(here.fingerprint.clone()), "the server knows who asked");

        let (port, served) = answer_once(there.clone());
        let other = here.agent(Some(&here.fingerprint), None, Duration::from_secs(5));
        let refused = other.get(&format!("https://127.0.0.1:{port}/listenook/info")).call();
        assert!(refused.is_err(), "a server with another certificate is not trusted");
        let _ = served.join();
    }

    fn root_kept(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("listenook-secure-{name}-{}", std::process::id()))
    }
}
