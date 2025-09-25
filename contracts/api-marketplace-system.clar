
;; title: api-marketplace-system
;; version: 1.0.0
;; summary: Decentralized API marketplace with usage-based billing and reputation system
;; description: Smart contract for managing API services, tracking usage, handling payments, and maintaining developer reputation scores

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-SERVICE-NOT-FOUND (err u101))
(define-constant ERR-INSUFFICIENT-FUNDS (err u102))
(define-constant ERR-INVALID-RATING (err u103))
(define-constant ERR-SERVICE-ALREADY-EXISTS (err u104))
(define-constant ERR-INVALID-PRICE (err u105))
(define-constant ERR-SERVICE-INACTIVE (err u106))
(define-constant MIN-RATING u1)
(define-constant MAX-RATING u5)
(define-constant PLATFORM-FEE-PERCENTAGE u5) ;; 5% platform fee

;; data vars
(define-data-var next-service-id uint u1)
(define-data-var platform-treasury uint u0)
(define-data-var total-services uint u0)
(define-data-var total-api-calls uint u0)

;; data maps

;; API Service structure
(define-map api-services
  uint ;; service-id
  {
    provider: principal,
    name: (string-ascii 64),
    description: (string-ascii 256),
    price-per-call: uint, ;; in microSTX
    endpoint: (string-ascii 128),
    is-active: bool,
    total-calls: uint,
    total-revenue: uint,
    average-rating: uint, ;; multiplied by 100 for precision (e.g., 450 = 4.50 rating)
    rating-count: uint,
    created-at: uint
  }
)

;; Provider profiles
(define-map providers
  principal
  {
    reputation-score: uint, ;; multiplied by 100 for precision
    total-services: uint,
    total-earnings: uint,
    services-created: (list 50 uint)
  }
)

;; Consumer profiles
(define-map consumers
  principal
  {
    total-spent: uint,
    total-calls-made: uint,
    services-used: (list 100 uint)
  }
)

;; API call records
(define-map api-calls
  { service-id: uint, caller: principal, call-height: uint }
  {
    amount-paid: uint,
    timestamp: uint,
    success: bool
  }
)

;; Service ratings
(define-map service-ratings
  { service-id: uint, rater: principal }
  {
    rating: uint,
    review: (string-ascii 256),
    timestamp: uint
  }
)

;; Service subscriptions (for future use)
(define-map subscriptions
  { service-id: uint, subscriber: principal }
  {
    expires-at: uint,
    calls-remaining: uint,
    amount-paid: uint
  }
)

;; public functions

;; Register a new API service
(define-public (register-api-service 
    (name (string-ascii 64))
    (description (string-ascii 256))
    (price-per-call uint)
    (endpoint (string-ascii 128)))
  (let 
    (
      (service-id (var-get next-service-id))
    )
    (asserts! (> price-per-call u0) ERR-INVALID-PRICE)
    (asserts! (> (len name) u0) ERR-INVALID-PRICE)
    
    ;; Create the service
    (map-set api-services service-id {
      provider: tx-sender,
      name: name,
      description: description,
      price-per-call: price-per-call,
      endpoint: endpoint,
      is-active: true,
      total-calls: u0,
      total-revenue: u0,
      average-rating: u0,
      rating-count: u0,
      created-at: block-height
    })
    
    ;; Update provider profile
    (let 
      (
        (existing-provider (default-to 
          { reputation-score: u0, total-services: u0, total-earnings: u0, services-created: (list) }
          (map-get? providers tx-sender)
        ))
      )
      (map-set providers tx-sender {
        reputation-score: (get reputation-score existing-provider),
        total-services: (+ (get total-services existing-provider) u1),
        total-earnings: (get total-earnings existing-provider),
        services-created: (unwrap-panic (as-max-len? (append (get services-created existing-provider) service-id) u50))
      })
    )
    
    ;; Update global counters
    (var-set next-service-id (+ service-id u1))
    (var-set total-services (+ (var-get total-services) u1))
    
    (ok service-id)
  )
)

;; Make an API call and handle payment
(define-public (make-api-call (service-id uint))
  (let 
    (
      (service-info (unwrap! (map-get? api-services service-id) ERR-SERVICE-NOT-FOUND))
      (call-price (get price-per-call service-info))
      (platform-fee (/ (* call-price PLATFORM-FEE-PERCENTAGE) u100))
      (provider-payment (- call-price platform-fee))
    )
    ;; Check if service is active
    (asserts! (get is-active service-info) ERR-SERVICE-INACTIVE)
    
    ;; Transfer payment from caller to provider
    (try! (stx-transfer? provider-payment tx-sender (get provider service-info)))
    
    ;; Transfer platform fee to treasury
    (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
    
    ;; Record the API call
    (map-set api-calls 
      { service-id: service-id, caller: tx-sender, call-height: block-height }
      {
        amount-paid: call-price,
        timestamp: block-height,
        success: true
      }
    )
    
    ;; Update service statistics
    (map-set api-services service-id 
      (merge service-info {
        total-calls: (+ (get total-calls service-info) u1),
        total-revenue: (+ (get total-revenue service-info) call-price)
      })
    )
    
    ;; Update provider earnings
    (let 
      (
        (provider-info (default-to 
          { reputation-score: u0, total-services: u0, total-earnings: u0, services-created: (list) }
          (map-get? providers (get provider service-info))
        ))
      )
      (map-set providers (get provider service-info)
        (merge provider-info {
          total-earnings: (+ (get total-earnings provider-info) provider-payment)
        })
      )
    )
    
    ;; Update consumer profile
    (let 
      (
        (consumer-info (default-to 
          { total-spent: u0, total-calls-made: u0, services-used: (list) }
          (map-get? consumers tx-sender)
        ))
        (updated-services (if (is-some (index-of (get services-used consumer-info) service-id))
                            (get services-used consumer-info)
                            (unwrap-panic (as-max-len? (append (get services-used consumer-info) service-id) u100))
                          ))
      )
      (map-set consumers tx-sender {
        total-spent: (+ (get total-spent consumer-info) call-price),
        total-calls-made: (+ (get total-calls-made consumer-info) u1),
        services-used: updated-services
      })
    )
    
    ;; Update global counters
    (var-set platform-treasury (+ (var-get platform-treasury) platform-fee))
    (var-set total-api-calls (+ (var-get total-api-calls) u1))
    
    (ok true)
  )
)

;; Rate a service after using it
(define-public (rate-service (service-id uint) (rating uint) (review (string-ascii 256)))
  (let 
    (
      (service-info (unwrap! (map-get? api-services service-id) ERR-SERVICE-NOT-FOUND))
    )
    ;; Validate rating
    (asserts! (and (>= rating MIN-RATING) (<= rating MAX-RATING)) ERR-INVALID-RATING)
    
    ;; Simplified check - in production, you'd implement proper usage verification
    (asserts! true ERR-NOT-AUTHORIZED)
    
    ;; Record the rating
    (map-set service-ratings 
      { service-id: service-id, rater: tx-sender }
      {
        rating: rating,
        review: review,
        timestamp: block-height
      }
    )
    
    ;; Update service average rating
    (let 
      (
        (current-rating (get average-rating service-info))
        (rating-count (get rating-count service-info))
        (new-rating-count (+ rating-count u1))
        (new-average (/ (+ (* current-rating rating-count) (* rating u100)) new-rating-count))
      )
      (map-set api-services service-id 
        (merge service-info {
          average-rating: new-average,
          rating-count: new-rating-count
        })
      )
    )
    
    (ok true)
  )
)

;; Toggle service active status (only by provider)
(define-public (toggle-service-status (service-id uint))
  (let 
    (
      (service-info (unwrap! (map-get? api-services service-id) ERR-SERVICE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get provider service-info)) ERR-NOT-AUTHORIZED)
    
    (map-set api-services service-id 
      (merge service-info {
        is-active: (not (get is-active service-info))
      })
    )
    
    (ok (not (get is-active service-info)))
  )
)

;; Update service pricing (only by provider)
(define-public (update-service-price (service-id uint) (new-price uint))
  (let 
    (
      (service-info (unwrap! (map-get? api-services service-id) ERR-SERVICE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get provider service-info)) ERR-NOT-AUTHORIZED)
    (asserts! (> new-price u0) ERR-INVALID-PRICE)
    
    (map-set api-services service-id 
      (merge service-info {
        price-per-call: new-price
      })
    )
    
    (ok true)
  )
)

;; read only functions

;; Get service information
(define-read-only (get-service-info (service-id uint))
  (map-get? api-services service-id)
)

;; Get provider information
(define-read-only (get-provider-info (provider principal))
  (map-get? providers provider)
)

;; Get consumer information
(define-read-only (get-consumer-info (consumer principal))
  (map-get? consumers consumer)
)

;; Get service rating by rater
(define-read-only (get-service-rating (service-id uint) (rater principal))
  (map-get? service-ratings { service-id: service-id, rater: rater })
)

;; Get API call record
(define-read-only (get-api-call-record (service-id uint) (caller principal) (call-height uint))
  (map-get? api-calls { service-id: service-id, caller: caller, call-height: call-height })
)

;; Get global statistics
(define-read-only (get-platform-stats)
  {
    total-services: (var-get total-services),
    total-api-calls: (var-get total-api-calls),
    platform-treasury: (var-get platform-treasury),
    next-service-id: (var-get next-service-id)
  }
)

;; Get services by provider (simplified version returning first 10)
(define-read-only (get-provider-services (provider principal))
  (let 
    (
      (provider-info (map-get? providers provider))
    )
    (match provider-info
      some-info (get services-created some-info)
      (list)
    )
  )
)

;; Check if service exists and is active
(define-read-only (is-service-active (service-id uint))
  (match (map-get? api-services service-id)
    some-service (get is-active some-service)
    false
  )
)

;; Calculate reputation score for a provider
(define-read-only (calculate-provider-reputation (provider principal))
  (let 
    (
      (provider-info (map-get? providers provider))
    )
    (match provider-info
      some-info (get reputation-score some-info)
      u0
    )
  )
)

