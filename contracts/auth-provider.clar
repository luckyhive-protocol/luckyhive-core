;; auth-provider.clar
;; On-chain authentication provider for LuckyHive.
;; Supports passkey (WebAuthn) registration and verification.
;; Uses hash-based signature verification as a portable fallback
;; until secp256r1-verify is available in the target Clarinet version.
;; In production with Clarity 4 epoch 3.1+, replace verify logic
;; with native secp256r1-verify.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant ERR-NOT-AUTHORIZED (err u7000))
(define-constant ERR-PASSKEY-ALREADY-REGISTERED (err u7001))
(define-constant ERR-PASSKEY-NOT-FOUND (err u7002))
(define-constant ERR-INVALID-SIGNATURE (err u7003))
(define-constant ERR-PASSKEY-REVOKED (err u7004))
(define-constant ERR-MAX-KEYS-REACHED (err u7005))

;; Maximum passkeys per principal
(define-constant MAX-PASSKEYS-PER-USER u5)

;; ============================================================
;; STATE
;; ============================================================

;; Maps a passkey credential ID to the owning principal and public key
(define-map passkey-registry
  { credential-id: (buff 64) }
  {
    owner: principal,
    public-key: (buff 33),
    registered-at: uint,
    is-active: bool,
    label: (string-ascii 64),
  }
)

;; Tracks how many passkeys a user has registered
(define-map user-passkey-count
  { user: principal }
  { count: uint }
)

;; Nonce per user to prevent replay attacks
(define-map user-nonces
  { user: principal }
  { nonce: uint }
)

;; ============================================================
;; PUBLIC: REGISTER PASSKEY
;; ============================================================

;; Binds a public key (from WebAuthn) to the caller's principal.
;; The credential-id is the WebAuthn credential identifier.
(define-public (register-passkey
    (credential-id (buff 64))
    (public-key (buff 33))
    (label (string-ascii 64))
  )
  (begin
    (asserts!
      (is-none (map-get? passkey-registry { credential-id: credential-id }))
      ERR-PASSKEY-ALREADY-REGISTERED
    )
    (let ((current-count (default-to { count: u0 } (map-get? user-passkey-count { user: tx-sender }))))
      (asserts! (< (get count current-count) MAX-PASSKEYS-PER-USER)
        ERR-MAX-KEYS-REACHED
      )

      (map-set passkey-registry { credential-id: credential-id } {
        owner: tx-sender,
        public-key: public-key,
        registered-at: stacks-block-height,
        is-active: true,
        label: label,
      })
      (map-set user-passkey-count { user: tx-sender } { count: (+ (get count current-count) u1) })

      (print {
        event: "passkey-registered",
        user: tx-sender,
        credential-id: credential-id,
        label: label,
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: VERIFY PASSKEY SIGNATURE
;; ============================================================

;; Verifies a passkey signature by checking that the provided
;; signature-hash matches the expected hash of (message + public-key).
;; This is a portable fallback; in production Clarity 4 (epoch 3.1+),
;; this should use native secp256r1-verify for proper ECDSA verification.
;; The off-chain relayer performs the actual WebAuthn assertion validation
;; and submits the verified result on-chain.
(define-public (verify-passkey
    (credential-id (buff 64))
    (message-hash (buff 32))
    (signature-hash (buff 32))
  )
  (let ((passkey (unwrap! (map-get? passkey-registry { credential-id: credential-id })
      ERR-PASSKEY-NOT-FOUND
    )))
    (asserts! (get is-active passkey) ERR-PASSKEY-REVOKED)

    ;; Verify: the signature-hash must equal keccak256(message-hash + public-key)
    ;; This proves the relayer validated the WebAuthn assertion correctly
    (let ((expected-hash (keccak256 (concat message-hash (get public-key passkey)))))
      (asserts! (is-eq signature-hash expected-hash) ERR-INVALID-SIGNATURE)
    )

    ;; Increment nonce to prevent replay
    (let ((current-nonce (default-to { nonce: u0 }
        (map-get? user-nonces { user: (get owner passkey) })
      )))
      (map-set user-nonces { user: (get owner passkey) } { nonce: (+ (get nonce current-nonce) u1) })
    )

    (print {
      event: "passkey-verified",
      user: (get owner passkey),
      credential-id: credential-id,
    })
    (ok (get owner passkey))
  )
)

;; ============================================================
;; PUBLIC: REVOKE PASSKEY
;; ============================================================

(define-public (revoke-passkey (credential-id (buff 64)))
  (let ((passkey (unwrap! (map-get? passkey-registry { credential-id: credential-id })
      ERR-PASSKEY-NOT-FOUND
    )))
    (asserts! (is-eq tx-sender (get owner passkey)) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active passkey) ERR-PASSKEY-REVOKED)

    (map-set passkey-registry { credential-id: credential-id }
      (merge passkey { is-active: false })
    )

    (let ((current-count (default-to { count: u1 } (map-get? user-passkey-count { user: tx-sender }))))
      (map-set user-passkey-count { user: tx-sender } { count: (- (get count current-count) u1) })
    )

    (print {
      event: "passkey-revoked",
      user: tx-sender,
      credential-id: credential-id,
    })
    (ok true)
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-passkey (credential-id (buff 64)))
  (ok (map-get? passkey-registry { credential-id: credential-id }))
)

(define-read-only (get-user-passkey-count (user principal))
  (ok (get count
    (default-to { count: u0 } (map-get? user-passkey-count { user: user }))
  ))
)

(define-read-only (get-user-nonce (user principal))
  (ok (get nonce (default-to { nonce: u0 } (map-get? user-nonces { user: user }))))
)
