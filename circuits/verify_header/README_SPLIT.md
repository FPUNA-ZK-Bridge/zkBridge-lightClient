# Verify Header - Split Circuits

Este directorio contiene los circuitos divididos para verificar headers de Ethereum con menos RAM.

## Problema Original

El circuito `verify_header.circom` original tiene ~120M constraints con 512 validadores, requiriendo ~300GB+ de RAM.

## Solución: División en 3 Partes

Dividimos el circuito en 3 partes que se ejecutan secuencialmente:

| Parte | Descripción | Constraints (b=512) | Constraints (b=8) |
|-------|-------------|---------------------|-------------------|
| Part1 | HashToField + Agregación + Checks + MapToG2 | ~106M | ~7M |
| Part2 | MillerLoop | ~8M | ~8M |
| Part3 | FinalExponentiate | ~5M | ~5M |

## Archivos

### Producción (512 validadores)
- `verify_header_part1.circom` - HashToField + Agregación + BLS Part1
- `verify_header_part2.circom` - MillerLoop
- `verify_header_part3.circom` - FinalExponentiate

### Testing (8 validadores) - Para máquinas con poca RAM
- `verify_header_mini_part1.circom` - ~7M constraints, ~15-20GB RAM
- `verify_header_mini_part2.circom` - ~8M constraints, ~20-25GB RAM
- `verify_header_mini_part3.circom` - ~5M constraints, ~12-15GB RAM

## Uso

### Versión Mini (para testing con 16GB RAM)

```bash
# Solo compilar (debería funcionar con 16GB)
./run_split.sh --mini --compile-only

# Compilar + generar witnesses
./run_split.sh --mini --witness-only

# Pipeline completo (requiere más RAM para zkeys)
./run_split.sh --mini --full
```

### Versión Producción (requiere ~100GB+ RAM)

```bash
# Solo compilar
./run_split.sh --compile-only

# Pipeline completo
./run_split.sh --full
```

### Pasos Individuales

```bash
# 1. Compilar circuitos
./run_split.sh [--mini] --compile-only

# 2. Generar witnesses (encadenados automáticamente)
./run_split.sh [--mini] --witness-only

# 3. Generar trusted setup (zkeys) - REQUIERE MUCHA RAM
./run_split.sh [--mini] --zkey-only

# 4. Generar proofs
./run_split.sh [--mini] --proof-only

# 5. Exportar verificadores Solidity
./run_split.sh [--mini] --export-verifiers

# 6. Ver resumen
./run_split.sh [--mini] --summary
```

## Encadenamiento de Pruebas

Las 3 pruebas se encadenan mediante valores públicos:

```
Part1 outputs:
  - Hm_G2[2][2][7]           → input de Part2
  - aggregated_pubkey[2][7]  → input de Part2
  - bitSum                   → output final
  - syncCommitteePoseidon    → output final

Part2 outputs:
  - miller_out[6][2][7]      → input de Part3

Part3:
  - Verifica que FinalExp(miller_out) == 1
```

## Verificación On-Chain

Para verificar en Solidity:
1. Verificar proof de Part1, extraer `Hm_G2` y `aggregated_pubkey` de public signals
2. Verificar proof de Part2 con los mismos `Hm_G2` y `aggregated_pubkey`
3. Verificar proof de Part3 con el mismo `miller_out`
4. Si las 3 pruebas son válidas y los valores encadenan correctamente, la firma es válida

## Requisitos

- circom 2.0.3+
- snarkjs 0.7+
- Node.js 16+
- Powers of Tau file (pot25_final.ptau o powersOfTau28_hez_final_27.ptau)

## RAM Estimada

| Modo | Compilación | Witness | zkey | Total |
|------|-------------|---------|------|-------|
| Mini (b=8) | ~8GB | ~4GB | ~20GB | ~25GB |
| Producción (b=512) | ~50GB | ~20GB | ~100GB | ~150GB |

Para la versión mini, usar swap puede permitir correr en máquinas con 16GB de RAM física.
