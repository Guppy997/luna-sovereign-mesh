#!/usr/bin/env bash
# Exportiert ein Kubernetes-Secret SOPS-verschlüsselt nach clusters/dev/secrets/.
# Der Klartext läuft nur durch die Pipe: nichts wird ausgegeben oder zwischengespeichert.
#
#   scripts/export-secret.sh <namespace> <name>   → clusters/dev/secrets/<namespace>-<name>.yaml
#
# Läuft dort, wo kubectl den Cluster erreicht und .sops.yaml gilt (Repo-Wurzel).
# Entfernt alle Annotationen: `kubectl.kubernetes.io/last-applied-configuration`
# enthält bei per `kubectl apply` angelegten Secrets sämtliche Werte im Klartext,
# und SOPS verschlüsselt laut .sops.yaml nur data/stringData.
set -Eeuo pipefail

ns=${1:?Aufruf: $0 <namespace> <name>}
name=${2:?Aufruf: $0 <namespace> <name>}
cd "$(dirname "$0")/.."
out="clusters/dev/secrets/${ns}-${name}.yaml"

kubectl get secret -n "$ns" "$name" -o yaml \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
m = d.get("metadata", {})
for k in ("uid", "resourceVersion", "creationTimestamp", "managedFields",
          "ownerReferences", "selfLink", "generation", "annotations"):
    m.pop(k, None)
yaml.safe_dump(d, sys.stdout, default_flow_style=False, sort_keys=False)
' \
  | sops -e --input-type yaml --output-type yaml --filename-override "$out" /dev/stdin > "$out.tmp"

# Außer den sops-Metadaten darf nur Struktur im Klartext stehen
if ! grep -q 'ENC\[' "$out.tmp" || ! python3 - "$out.tmp" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
allowed_meta = {"name", "namespace", "labels"}
ok = set(d) <= {"apiVersion", "kind", "metadata", "type", "data", "stringData", "immutable", "sops"} \
     and set(d.get("metadata", {})) <= allowed_meta \
     and all(str(v).startswith("ENC[") for k in ("data", "stringData") for v in (d.get(k) or {}).values())
sys.exit(0 if ok else 1)
EOF
then
  rm -f "$out.tmp"
  echo "FEHLER: $out ist nicht vollständig verschlüsselt, nichts geschrieben" >&2
  exit 1
fi
mv "$out.tmp" "$out"
echo "exportiert: $out ($(grep -c 'ENC\[' "$out") verschlüsselte Werte)"
