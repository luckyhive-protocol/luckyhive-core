;; vault-factory.clar
;; Manages permissionless yield strategies for LuckyHive.
;; Routes deposited assets to yield-generating sources (PoX stacking, sBTC Dual Stacking)
;; and harvests yield back to the prize pool.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u4000))
(define-constant ERR-VAULT-EXISTS (err u4001))
(define-constant ERR-VAULT-NOT-FOUND (err u4002))
(define-constant ERR-VAULT-INACTIVE (err u4003))
(define-constant ERR-INVALID-AMOUNT (err u4004))
(define-constant ERR-NO-YIELD (err u4005))
(define-constant ERR-MAX-VAULTS (err u4006))

(define-constant MAX-VAULTS u10)

;; ============================================================
;; STATE
;; ============================================================

(define-data-var vault-counter uint u0)
(define-data-var total-deployed uint u0)
(define-data-var total-harvested uint u0)

;; Vault registry
(define-map vaults
  { vault-id: uint }
  {
    name: (string-ascii 64),
    vault-principal: principal,
    is-active: bool,
    deployed-amount: uint,
    harvested-amount: uint,
    registered-at: uint
  }
)

;; Vault lookup by principal
(define-map vault-by-principal
  { vault-principal: principal }
  { vault-id: uint }
)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; ============================================================
;; PUBLIC: REGISTER VAULT
;; ============================================================

;; Register a new yield vault. In production, this would verify
;; the contract code hash against a known template.
(define-public (register-vault (name (string-ascii 64)) (vault-principal principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? vault-by-principal { vault-principal: vault-principal })) ERR-VAULT-EXISTS)
    (asserts! (< (var-get vault-counter) MAX-VAULTS) ERR-MAX-VAULTS)

    (let (
      (vault-id (+ (var-get vault-counter) u1))
    )
      (map-set vaults
        { vault-id: vault-id }
        {
          name: name,
          vault-principal: vault-principal,
          is-active: true,
          deployed-amount: u0,
          harvested-amount: u0,
          registered-at: stacks-block-height
        }
      )
      (map-set vault-by-principal
        { vault-principal: vault-principal }
        { vault-id: vault-id }
      )
      (var-set vault-counter vault-id)

      (print {
        event: "vault-registered",
        vault-id: vault-id,
        name: name,
        vault-principal: vault-principal
      })
      (ok vault-id)
    )
  )
)

;; ============================================================
;; PUBLIC: DEPLOY FUNDS
;; ============================================================

;; Deploy STX to a specific vault for yield generation.
;; In production, this calls the vault contract's deposit function.
(define-public (deploy-funds (vault-id uint) (amount uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)

    (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
    )
      (asserts! (get is-active vault) ERR-VAULT-INACTIVE)

      ;; Update vault state
      (map-set vaults
        { vault-id: vault-id }
        (merge vault { deployed-amount: (+ (get deployed-amount vault) amount) })
      )
      (var-set total-deployed (+ (var-get total-deployed) amount))

      (print {
        event: "funds-deployed",
        vault-id: vault-id,
        amount: amount,
        total-deployed: (+ (get deployed-amount vault) amount)
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: HARVEST YIELD
;; ============================================================

;; Harvest yield from a vault and route it to the prize pool.
;; In production, this calls the vault's withdraw-yield function
;; and forwards the proceeds to prize-pool.add-yield.
(define-public (harvest-yield (vault-id uint) (yield-amount uint))
  (begin
    (asserts! (> yield-amount u0) ERR-NO-YIELD)

    (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
    )
      (asserts! (get is-active vault) ERR-VAULT-INACTIVE)

      ;; Forward yield to prize pool
      (try! (contract-call? .prize-pool add-yield yield-amount))

      ;; Update vault state
      (map-set vaults
        { vault-id: vault-id }
        (merge vault { harvested-amount: (+ (get harvested-amount vault) yield-amount) })
      )
      (var-set total-harvested (+ (var-get total-harvested) yield-amount))

      (print {
        event: "yield-harvested",
        vault-id: vault-id,
        yield-amount: yield-amount,
        total-harvested: (+ (get harvested-amount vault) yield-amount)
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: DEACTIVATE VAULT
;; ============================================================

(define-public (deactivate-vault (vault-id uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
    )
      (map-set vaults
        { vault-id: vault-id }
        (merge vault { is-active: false })
      )
      (print { event: "vault-deactivated", vault-id: vault-id })
      (ok true)
    )
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-vault (vault-id uint))
  (ok (map-get? vaults { vault-id: vault-id }))
)

(define-read-only (get-vault-count)
  (ok (var-get vault-counter))
)

(define-read-only (get-factory-stats)
  (ok {
    total-vaults: (var-get vault-counter),
    total-deployed: (var-get total-deployed),
    total-harvested: (var-get total-harvested)
  })
)
