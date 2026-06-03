#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Epoch Names — Post-deploy mainnet setup
#
# Eseguire NELL'ORDINE dopo il deploy del package.
# Richiede: sui CLI configurata su mainnet con il wallet admin
#
# Sostituire le variabili prima di eseguire:
#   PACKAGE_ID   — da output di "sui client publish"
#   PUBLISHER    — da output di "sui client publish" (oggetto Publisher)
#   TREASURY_ID  — da output di "sui client publish"
#   ADMIN_CAP    — da output di "sui client publish"
#   MARKETPLACE_CAP — da output di "sui client publish"
# ══════════════════════════════════════════════════════════════

PACKAGE_ID="<INSERISCI_PACKAGE_ID>"
PUBLISHER="<INSERISCI_PUBLISHER_OBJECT_ID>"
TREASURY_ID="<INSERISCI_TREASURY_ID>"
ADMIN_CAP="<INSERISCI_ADMIN_CAP_ID>"
MARKETPLACE_CAP="<INSERISCI_MARKETPLACE_CAP_ID>"
GAS_BUDGET=100000000

echo "========================================"
echo "STEP 1 — init_policy"
echo "Crea TransferPolicy<NameCap> con royalty 1%"
echo "========================================"
sui client call \
  --package "$PACKAGE_ID" \
  --module marketplace \
  --function init_policy \
  --args "$PUBLISHER" \
  --gas-budget $GAS_BUDGET

echo ""
echo "========================================"
echo "STEP 2 — burn_publisher"
echo "Brucia il Publisher (irreversibile!)"
echo "Assicurati che init_policy sia andato a buon fine prima."
echo "========================================"
read -p "Premi ENTER per continuare con burn_publisher, CTRL+C per annullare..."

sui client call \
  --package "$PACKAGE_ID" \
  --module walrus_names \
  --function burn_publisher \
  --args "$PUBLISHER" \
  --gas-budget $GAS_BUDGET

echo ""
echo "========================================"
echo "STEP 3 — Annota tutti gli indirizzi"
echo "Aggiorna walrus-names-frontend/src/utils/marketplace.ts"
echo "========================================"
echo "PACKAGE_ID:     $PACKAGE_ID"
echo "TREASURY_ID:    $TREASURY_ID"
echo "ADMIN_CAP:      $ADMIN_CAP"
echo "MARKETPLACE_CAP: $MARKETPLACE_CAP"
echo ""
echo "Cerca anche negli output:"
echo "  - REGISTRY_ID        (oggetto Registry creato da init)"
echo "  - TRANSFER_POLICY_ID (creato da init_policy)"
echo "  - TRANSFER_POLICY_CAP (creato da init_policy)"
echo ""
echo "✓ Deploy mainnet completato"
