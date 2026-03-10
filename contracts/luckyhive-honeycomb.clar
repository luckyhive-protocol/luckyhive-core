;; honeycomb-token.clar
;; SIP-010 compliant receipt token for LuckyHive deposits.
;; Minted 1:1 on deposit into the Honeycomb (prize pool),
;; burned on withdrawal. Only the prize-pool contract may mint/burn.

;; ============================================================
;; TRAITS
;; ============================================================

(impl-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-NOT-TOKEN-OWNER (err u1001))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1002))
(define-constant ERR-INVALID-AMOUNT (err u1003))
(define-constant TOKEN-NAME "Honeycomb")
(define-constant TOKEN-SYMBOL "HCOMB")
(define-constant TOKEN-DECIMALS u6)

;; ============================================================
;; STATE
;; ============================================================

(define-fungible-token honeycomb)
(define-data-var token-uri (optional (string-utf8 256)) (some u"https://luckyhive.xyz/token/honeycomb.json"))
(define-data-var authorized-minter principal CONTRACT-OWNER)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-authorized-minter)
  (is-eq contract-caller (var-get authorized-minter))
)

;; ============================================================
;; SIP-010 INTERFACE
;; ============================================================

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR-NOT-TOKEN-OWNER)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (match memo
      memo-val (print memo-val)
      0x
    )
    (ft-transfer? honeycomb amount sender recipient)
  )
)

(define-read-only (get-name)
  (ok TOKEN-NAME)
)

(define-read-only (get-symbol)
  (ok TOKEN-SYMBOL)
)

(define-read-only (get-decimals)
  (ok TOKEN-DECIMALS)
)

(define-read-only (get-balance (account principal))
  (ok (ft-get-balance honeycomb account))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply honeycomb))
)

(define-read-only (get-token-uri)
  (ok (var-get token-uri))
)

;; ============================================================
;; MINT / BURN (restricted to prize-pool)
;; ============================================================

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-authorized-minter) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (print { event: "honeycomb-minted", recipient: recipient, amount: amount })
    (ft-mint? honeycomb amount recipient)
  )
)

(define-public (burn (amount uint) (owner principal))
  (begin
    (asserts! (is-authorized-minter) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= (ft-get-balance honeycomb owner) amount) ERR-INSUFFICIENT-BALANCE)
    (print { event: "honeycomb-burned", owner: owner, amount: amount })
    (ft-burn? honeycomb amount owner)
  )
)

;; ============================================================
;; ADMIN
;; ============================================================

(define-public (set-authorized-minter (new-minter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (print { event: "minter-updated", old-minter: (var-get authorized-minter), new-minter: new-minter })
    (ok (var-set authorized-minter new-minter))
  )
)

(define-public (set-token-uri (new-uri (optional (string-utf8 256))))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (var-set token-uri new-uri))
  )
)
