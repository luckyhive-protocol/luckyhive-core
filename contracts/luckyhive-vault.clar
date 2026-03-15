;; luckyhive-vault.clar
;; Yield source for LuckyHive Prize Pool.
;;
;; Phase 1 (Testnet): Admin seeds yield manually via seed-yield.
;;   The vault accepts STX and forwards it to the prize pool as yield.
;;
;; Phase 2 (Mainnet): Integrates with StackingDAO (stSTX) for real
;;   auto-compounding yield from PoX stacking rewards.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u4000))
(define-constant ERR-INVALID-AMOUNT (err u4001))
(define-constant ERR-PAUSED (err u4002))

;; ============================================================
;; STATE
;; ============================================================

(define-data-var vault-paused bool false)
(define-data-var total-seeded uint u0)       ;; Total STX seeded by admin
(define-data-var total-forwarded uint u0)    ;; Total STX forwarded to prize pool
(define-data-var pending-yield uint u0)      ;; STX waiting to be forwarded

;; Track yield history per cycle
(define-data-var seed-counter uint u0)
(define-map seed-history
  { seed-id: uint }
  {
    seeder: principal,
    amount: uint,
    block-height: uint,
  }
)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (assert-not-paused)
  (ok (asserts! (not (var-get vault-paused)) ERR-PAUSED))
)

;; ============================================================
;; PUBLIC: SEED YIELD (Phase 1 - manual yield injection)
;; ============================================================

;; Admin deposits STX into the vault as simulated yield.
;; This accumulates in pending-yield until forwarded.
(define-public (seed-yield (amount uint))
  (begin
    (try! (assert-not-paused))
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)

    ;; Transfer STX from admin to this vault contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

    ;; Update accounting
    (let ((seed-id (+ (var-get seed-counter) u1)))
      (var-set total-seeded (+ (var-get total-seeded) amount))
      (var-set pending-yield (+ (var-get pending-yield) amount))
      (var-set seed-counter seed-id)

      (map-set seed-history { seed-id: seed-id } {
        seeder: tx-sender,
        amount: amount,
        block-height: stacks-block-height,
      })

      (print {
        event: "yield-seeded",
        seed-id: seed-id,
        seeder: tx-sender,
        amount: amount,
        pending-yield: (var-get pending-yield),
      })
      (ok seed-id)
    )
  )
)

;; ============================================================
;; PUBLIC: FORWARD YIELD TO PRIZE POOL
;; ============================================================

;; Forwards all pending yield to the prize pool.
;; Can be called by admin or an automated bot.
(define-public (forward-yield)
  (let (
      (yield-to-forward (var-get pending-yield))
    )
    (begin
      (try! (assert-not-paused))
      (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
      (asserts! (> yield-to-forward u0) ERR-INVALID-AMOUNT)

      ;; Transfer STX from vault to prize pool via add-yield
      ;; The vault contract is authorized to call add-yield
      (try! (as-contract (contract-call? .luckyhive-prize-pool add-yield yield-to-forward)))

      ;; Update accounting
      (var-set pending-yield u0)
      (var-set total-forwarded (+ (var-get total-forwarded) yield-to-forward))

      (print {
        event: "yield-forwarded",
        amount: yield-to-forward,
        total-forwarded: (var-get total-forwarded),
      })
      (ok yield-to-forward)
    )
  )
)

;; ============================================================
;; PUBLIC: SEED AND FORWARD (convenience)
;; ============================================================

;; Single-call: seed yield and immediately forward it to the prize pool.
(define-public (seed-and-forward (amount uint))
  (begin
    (try! (seed-yield amount))
    (try! (forward-yield))
    (ok amount)
  )
)

;; ============================================================
;; ADMIN
;; ============================================================

(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set vault-paused paused))
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-vault-stats)
  (ok {
    total-seeded: (var-get total-seeded),
    total-forwarded: (var-get total-forwarded),
    pending-yield: (var-get pending-yield),
    seed-count: (var-get seed-counter),
    is-paused: (var-get vault-paused),
  })
)

(define-read-only (get-seed-info (seed-id uint))
  (ok (map-get? seed-history { seed-id: seed-id }))
)
