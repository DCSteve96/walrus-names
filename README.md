# Walrus Names — Move Smart Contract

Decentralized name service on Sui. Register `.epoch` names as NFTs, host permanent websites on Walrus, and trade names on a fully on-chain marketplace with royalty enforcement.

---

## Deployments

| Network | Version | Package ID |
|---------|---------|------------|
| Mainnet | v2 (current) | `0x5b4331514eb2822fde9ab5160ddf93e8fc299f7f20376d3b60fc11e68dc8128c` |
| Mainnet | v1 (legacy)  | `0xdfc2fc0fc0a758b8627d4ad91568a7e895225fca9a1315164d52ac2057a956bc` |
| Testnet | v3 (current) | `0xcc0f0f044e3e37bc081d11cb8c4e955edfa59840decfe7705e182e931091706b` |
| Testnet | v2 (legacy)  | `0x7e2d86522690b98160765278f6c63c84754e4e817948ed0ae2a80e2dd13231b6` |

### Shared objects (mainnet)

| Object | ID |
|--------|----|
| Registry | `0x7f0723b015f22e3f75356b12c3b791fbfc9f71072c0174b8c53dc9a92d86e3c3` |
| Treasury | `0xab539cc13e1d2cdb5708cd90004fb1fba3262c9c394eb38aa821c52c5716ee38` |
| TransferPolicy | `0x4cdc0ffdadbfe9027f1b005b58af47bf1610f2ce5b263f74c58c0f1cf1050753` |
| UpgradeCap | `0x37b085a189492b498b565f03810290d25d6991047c229f455d472ca6d38572af` |

---

## Modules

### `walrus_names`
Core name service. Handles registration, blob updates, transfers, and fee management.

**Key functions:**
- `register(registry, treasury, name, blob_id, payment, ctx)` — Register a new `.epoch` name. Fee based on length (3-char = 12.5 SUI, 4-char = 2.5 SUI, 5+ = 0.5 SUI on mainnet). Whitelisted wallets register free.
- `update_blob(registry, cap, new_blob_id, ctx)` — Update the Walrus site blob for an owned name.
- `transfer_name(registry, cap, to, ctx)` — Transfer a name to another address (registry kept in sync).

**Events:** `NameRegistered`, `BlobUpdated`, `NameTransferred`

### `marketplace`
Kiosk-based secondary market. All sales enforce a mandatory 1% royalty via `TransferPolicy`.

**Key functions:**
- `list_name(kiosk, kiosk_cap, registry, cap, price, ctx)` — List a name for sale. Locks the `NameCap` in the seller's kiosk.
- `delist_name(kiosk, kiosk_cap, name_cap_id, ctx)` — Delist a name. Returns `NameCap` to the seller.
- `buy_name(seller_kiosk, policy, registry, name_cap_id, price, payment, ctx)` — Buy a listed name. Buyer pays `price + ceil(price * 1%)`. Royalty deposited into `TransferPolicy` balance.
- `place_offer(registry, name_cap_id, name, expiry_ms, payment, ctx)` — Place an on-chain bid. SUI is locked in a shared `Offer` object. `expiry_ms = 0` means no expiry.
- `accept_offer(offer, kiosk, kiosk_cap, policy, registry, ctx)` — Seller accepts a bid. Atomically delists the name, pays seller (minus 1% royalty), transfers name to bidder.
- `cancel_offer(offer, ctx)` — Bidder cancels their own offer. SUI returned immediately.
- `reclaim_expired_offer(offer, clock, ctx)` — Anyone can reclaim SUI from an expired offer (when `expiry_ms > 0` and past).

**Events:** `NameListed`, `NameDelisted`, `NameSold`, `OfferPlaced`, `OfferAccepted`, `OfferCancelled`

### `royalty_rule`
Custom transfer policy rule that enforces the 1% royalty on every kiosk purchase. Used by both `buy_name` and `accept_offer` paths — there is no way to complete a purchase without paying it.

---

## Changelog

### v2 / mainnet (upgrade TX: `7jw7NqXLzEpWNRJSTNvQiRPzrf74kXq7CA2SDqigdApq`)
### v3 / testnet (upgrade TX: `3hJuBPQS6LqRUDvBZZWnhQuwmWp9DNTqocBnbnEdJy6N`)

Added full **bid (offer) system**:

- **`Offer` shared object** — when a buyer calls `place_offer`, their SUI is locked in a new shared `Offer` object on-chain. The object stores: `name`, `name_cap_id`, `bidder`, `payment` (locked coins), `expiry` (optional Unix ms timestamp).
- **`place_offer`** — buyer locks SUI on-chain. Requires the name to exist in the registry (B-1 check). Emits `OfferPlaced`.
- **`accept_offer`** — seller atomically: delists the name from their kiosk, verifies cap matches the offer (B-1 secondary gate), collects royalty fee, pays themselves the remainder, transfers name to bidder. Emits `OfferAccepted`.
- **`cancel_offer`** — only the original bidder can cancel. SUI returned immediately. Emits `OfferCancelled`.
- **`reclaim_expired_offer`** — permissionless reclaim after expiry. Anyone can call it; SUI always goes back to the bidder. Emits `OfferCancelled`. Offers with `expiry = 0` never expire and can only be cancelled by the bidder.

**Security properties of the bid system:**
- **B-1**: `place_offer` checks the name exists in the registry — prevents bids on non-existent names.
- **B-2**: `reclaim_expired_offer` requires `expiry > 0 && clock >= expiry` — prevents premature reclaim.
- **B-3**: `accept_offer` verifies `registry.owner_of(name) == seller` — prevents a non-owner from accepting.
- **B-4**: royalty is deducted from the offer amount; if net amount is 0 the coin is destroyed rather than transferred (prevents zero-transfer abort).
- **M-3 (self-buy)**: `accept_offer` checks `seller != bidder` — no self-deals.
- **H-1 (registry sync)**: name cap identity is verified against the registry on both `list_name` and `accept_offer`.

---

## Architecture notes

- The `TransferPolicy<NameCap>` is shared across all package versions — it does not change on upgrade.
- The `Publisher` was burned after `init_policy` was called — no new policies can be created, and the existing 1% royalty rule is permanent.
- `accept_offer` uses `royalty_rule::deposit` directly (not via `TransferRequest`) — this is the approved bypass for non-kiosk-purchase paths where the buyer already has an off-chain commitment.
- All entry functions are `public fun` (not `entry`) to allow composition in PTBs.

---

## Build & test

```bash
# Build
sui move build

# Test
sui move test

# Upgrade (mainnet)
sui client upgrade \
  --upgrade-capability 0x37b085a189492b498b565f03810290d25d6991047c229f455d472ca6d38572af \
  --gas-budget 300000000
```

> **Note:** `Move.toml` must have `published-at` set to the current package ID before upgrading.
