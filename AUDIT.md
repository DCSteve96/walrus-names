# Audit di sicurezza — Walrus Names (audit completo da zero)

**Data:** 3 giugno 2026 · **Rev:** 6 (riscrittura completa + analisi blocchi/liveness)
**Scope:** `sources/walrus_names.move` (563), `sources/marketplace.move` (426), `sources/royalty_rule.move` (123)
**Metodo:** revisione statica manuale dei tre moduli + verifica del comportamento di Kiosk / TransferPolicy / package sui sorgenti Sui in `build/` + suite di test (`sui move test`).

> ⚠️ Non ho eseguito `sui move build`/`test` in questo ambiente (CLI assente). Compilazione e test li lanci tu. Questo è un audit interno: **non sostituisce** un audit esterno indipendente.

---

## 1. Sintesi

Custodia dei nomi e sicurezza dei fondi utente: **solide**. Nessun percorso permette di rubare un nome senza la `NameCap`, né di prelevare dal treasury senza `AdminCap`, né di drenare le royalty senza `TransferPolicyCap`. Le aree di rischio residue sono **(a) la revenue/fee** e **(b) la liveness** — cioè stati in cui il contratto si blocca, quasi tutti legati alla custodia delle capability o a un upgrade gestito male.

| Sev | ID | Titolo | Tipo |
|-----|----|--------|------|
| 🟠 Med | R-1 | Cap del 10% sulla royalty aggirabile via `royalty_rule::update_fee` diretto | Fee / centralizzazione |
| 🟠 Med | BLOCK-1 | Perdita dell'`AdminCap` → dopo un upgrade `migrate()` impossibile → contratto congelato | Liveness |
| 🟠 Med | BLOCK-3 | `fee_bps > 10000` blocca tutte le compre e accettazioni offerte | Liveness (recuperabile) |
| 🟡 Low | N-1 | Royalty enforcement dipende dal burn del Publisher | Fee |
| 🟡 Low | BLOCK-2 | Handoff admin: `transfer_admin_to_pending` manda la cap prima dell'accept | Liveness operativa |
| 🟡 Low | BLOCK-4 | Offer con `expiry == 0` + chiave bidder persa → fondi del bidder bloccati | Liveness (solo bidder) |
| 🟡 Low | OF-1 | `accept_offer` ignora `expiry`: offerta scaduta ancora accettabile | Semantica |
| 🟡 Low | OF-2 | `OfferPlaced` con `name_cap_id` non legato al `name` → eventi spoofabili | Integrità indexer |
| ⚪ Info | I-1..4 | Nomi permanenti, transfer a 0x0, fee_base=0, doppio-cap illusorio | Design |

Nessun finding **Critical**. Nessun rischio diretto sui fondi degli utenti o sulla proprietà dei nomi.

---

## 2. Findings sicurezza

### 🟠 R-1 — Il cap del 10% sulla royalty è aggirabile

`royalty_rule::add` e `royalty_rule::update_fee` (`royalty_rule.move:53,62`) sono `public` e **non applicano alcun limite** a `fee_bps`. Il cap `MAX_FEE_BPS` (10%) è verificato solo in `marketplace::update_policy_fee`. Chi detiene il `TransferPolicyCap` chiama direttamente `royalty_rule::update_fee(policy, policy_cap, 10000)` e impone una royalty del 100%.

- **Rug sul secondario:** con `fee_bps = 10000` il seller riceve 0, tutto va nella policy balance (prelevabile dall'admin). Contraddice la promessa "trustless".
- **Doppio-cap illusorio:** `update_policy_fee` chiede `MarketplaceCap` + `TransferPolicyCap`, ma `royalty_rule::update_fee` richiede solo il secondo → il primo non è una vera protezione.

**Fix:** spostare `assert!(fee_bps <= MAX_FEE_BPS)` dentro `royalty_rule::add`/`update_fee`, oppure renderle `public(package)` così l'unica via resta `update_policy_fee`. Definire `MAX_FEE_BPS` in `royalty_rule`.

### 🟡 N-1 — La royalty è davvero blindata solo dopo il burn del Publisher

`confirm_request` lega la `TransferRequest` solo al **tipo** `NameCap`, non a uno specifico oggetto policy. Se esistesse una **seconda** `TransferPolicy<NameCap>` senza rule, un compratore confermerebbe contro quella saltando la royalty (riapre H-A). Creare una seconda policy richiede il `Publisher`, oggi nel wallet del deployer. **Azione pre-mainnet:** dopo `init_policy`, chiamare `walrus_names::burn_publisher(publisher)`. Su testnet è ininfluente.

### 🟡 OF-2 — `OfferPlaced` parzialmente spoofabile

`place_offer` ora esige che il `name` sia registrato (buon fix B-1), ma `name_cap_id` resta input non legato al `name` al momento del placement. Si può emettere un `OfferPlaced` con `name` reale e `name_cap_id` errato: l'offerta non sarà mai accettabile (lo blocca `assert name_of(&cap) == name` in `accept_offer`), ma inquina l'indexer. Mitigazione lato indexer: trattare `OfferPlaced` come provvisorio fino a `OfferAccepted`.

### 🟡 OF-1 — `accept_offer` ignora la scadenza

`accept_offer` non controlla `expiry`: un'offerta scaduta ma non ancora reclamata resta **accettabile** dal seller. Il bidder riceve comunque il nome, ma potrebbe non volerlo più. Per semantica pulita: `assert!(offer.expiry == 0 || clock < offer.expiry)` in `accept_offer`, oppure documentare che la scadenza abilita solo il reclaim.

---

## 3. Analisi blocchi / liveness (stati congelati)

Questa è la parte richiesta: dove il contratto può **bloccarsi**.

### 🟠 BLOCK-1 — Perdita dell'AdminCap → freeze totale dopo un upgrade

Quasi tutte le funzioni che mutano stato sono version-gated (`assert!(version == VERSION)`). Dopo un `package upgrade` la `VERSION` del nuovo package sale, ma gli oggetti restano alla vecchia versione finché non si chiama `migrate()`, che richiede l'`AdminCap`. Quindi:

- Se l'`AdminCap` è **perso o bruciato**, dopo un upgrade `migrate()` è impossibile → ogni funzione gated (register, buy, transfer_name, withdraw_fees, offerte…) aborta **per sempre**. Nomi e fondi del treasury congelati.
- Anche senza upgrade, `withdraw_fees`/`update_fee` e l'intera gestione admin diventano inservibili se la cap è persa.

**Mitigazione:** custodire l'`AdminCap` in multisig; non bruciarla mai; procedura di handoff rigorosa (vedi BLOCK-2). Valutare se il version-gating su funzioni *user* (es. `register`) sia desiderato: blocca gli utenti finché l'admin non migra.

### 🟠 BLOCK-3 — `fee_bps > 10000` blocca compre e offerte

Conseguenza diretta di R-1: con `fee_bps > 10000`, in `buy_name` e `accept_offer` la fee calcolata supera l'importo → `coin::split(payment, fee)` aborta → **nessuna vendita né accettazione offerta possibile** finché la fee non viene riabbassata. Recuperabile dall'admin, ma è un blocco dell'intero marketplace innescabile dal detentore del `TransferPolicyCap` (o da una chiave compromessa). Si chiude con il fix R-1.

### 🟡 BLOCK-2 — Handoff admin: la cap parte prima dell'accept

In `transfer_admin_to_pending` la `AdminCap` viene trasferita a `pending_admin` **prima** che questo chiami `accept_admin`. Se `proposed` è un indirizzo sbagliato/morto (typo), la cap finisce lì ed è **persa per sempre** → scenario BLOCK-1. `cancel_admin_proposal` protegge solo *prima* dello step 2. **Mitigazione:** verificare l'indirizzo prima di `transfer_admin_to_pending`; idealmente far sì che il nuovo admin esegua una tx di "prova" prima del passaggio.

### 🟡 BLOCK-4 — Offerta senza scadenza + chiave persa = fondi bloccati

Un `Offer` con `expiry == 0` si recupera solo con `cancel_offer` (richiede il bidder); `reclaim_expired_offer` richiede `expiry > 0`. Se il bidder perde la chiave, il suo SUI resta bloccato a meno che un seller non accetti l'offerta. Riguarda solo i fondi di quel bidder. **Mitigazione:** incoraggiare nel frontend una `expiry` sempre > 0; oppure consentire il reclaim dopo un tetto massimo anche con `expiry == 0`.

### ⚪ Altri stati verificati — NON bloccanti

- **`migrate()` doppio:** seconda chiamata aborta (`version < VERSION` falso). Idempotente, nessun blocco. Le due versioni (treasury/registry) si alzano **insieme**, niente desync dalle funzioni esistenti.
- **`delist_name` / `cancel_offer` / `reclaim_expired_offer`** non version-gated: corretto — devono funzionare sempre, anche cross-upgrade, e operano solo su oggetti del chiamante. Garantiscono il recupero dei fondi anche se il resto è in attesa di `migrate`.
- **Desync registry/NameCap (M-2):** recuperabile con `sync_owner`; non è un blocco permanente.
- **Crescita illimitata della Table dei nomi:** accesso O(1) via dynamic field, nessun blocco.
- **`name` trasferito a `@0x0`:** il nome resta congelato (errore utente, non exploit) — vedi I-2.

---

## 4. Conferme positive (riverificate da zero)

| Verifica | Esito |
|----------|-------|
| Furto di un nome senza `NameCap` | ❌ impossibile |
| Prelievo treasury senza `AdminCap` | ❌ impossibile |
| Drenare royalty senza `TransferPolicyCap` | ❌ impossibile |
| Contabilità coin di `buy_name` | ✅ bilanciata (`listed_price` deve = prezzo kiosk o `kiosk::purchase` aborta; le due fee coincidono) |
| Escrow degli offer | ✅ monouso, estraibile solo da accept (seller) o cancel/reclaim (→ bidder) |
| Whitelist one-shot | ✅ consumo atomico; revert non brucia il grant; blocca anche multi-uso in stessa PTB |
| Matematica fee per `fee_bps ≤ 10000` | ✅ `fee ≤ amount`, `coin::split` safe, dust gestito (B-4) |
| Doppia spesa / doppia accettazione offerta | ❌ `Offer` consumato by-value, `id` cancellato |
| Self-buy / self-accept / self-proposal | ❌ bloccati |
| Validazione nomi (numerici, `xn--`, dash, multibyte) | ✅ solo ASCII `a-z0-9-`, almeno una lettera |
| Reentrancy / flash loan | ❌ non applicabile in Move |
| Overflow calcolo fee | ✅ `u128` intermedio; overflow `u64` → abort safe |

---

## 5. Checklist pre-mainnet (in ordine)

1. **R-1:** spostare il cap `MAX_FEE_BPS` dentro `royalty_rule` (chiude anche BLOCK-3).
2. **N-1:** dopo `init_policy`, eseguire `burn_publisher` (chiude H-A in via definitiva).
3. **BLOCK-1/BLOCK-2:** `AdminCap` in multisig; procedura di handoff con verifica indirizzo prima dello step 2.
4. **OF-1/OF-2:** `assert` not-expired in `accept_offer`; indexer tratta `OfferPlaced` come provvisorio.
5. **BLOCK-4:** frontend impone sempre `expiry > 0` sulle offerte.
6. Lanciare `sui move test` (suite attuale) e aggiungere i test di regressione per R-1 e per il not-expired.
7. **Audit esterno indipendente** prima del lancio con fondi reali.

---

## 6. Note informative

- **I-1 — Nomi permanenti:** nessuna scadenza/rinnovo, squatting possibile. Scelta economica.
- **I-2 — Transfer a `@0x0`:** `transfer_name`/`sync_owner` non vietano `to == @0x0` → nome congelato. Valuta un assert.
- **I-3 — `fee_base = 0`:** l'admin può rendere gratis la registrazione per tutti. Capability voluta, da rendere esplicita.
- **I-4 — Doppio-cap illusorio:** vedi R-1.
- **Version-gating:** ricordarsi di **incrementare `VERSION`** ad ogni upgrade, altrimenti vecchio e nuovo package restano entrambi attivi (il gating non protegge).
