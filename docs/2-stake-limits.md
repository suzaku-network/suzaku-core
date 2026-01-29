# Stake & Weight Limiting Factors

This document provides a comprehensive reference of all variables that limit stake/weight across different entities in the Suzaku protocol.

---

## Overview

Stake capacity flows top-down from the Avalanche L1 (unlimited) through increasingly constrained layers:

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#e2e8f0', 'primaryTextColor': '#1e293b', 'lineColor': '#64748b'}}}%%
flowchart TB
    L1[Avalanche L1<br/>]
    
    L1 -->|churnRate: 20%/period| BVM[BalancerValidatorManager]
    
    BVM -->|maxWeight: 60%| POA[PoA Module<br/>60%]
    BVM -->|maxWeight: 40%| POS[PoS Middleware<br/>40%]
    
    POS --> VA[Vault A<br/>L1 cap: 5000<br/>curator cap: 4000 - 23%]
    POS --> VB[Vault B<br/>L1 cap: 4000<br/>curator cap: 3000 - 17%]
    
    VA -->|shares: 60%| OP1[Operator 1<br/>3150 - 18%]
    VA -->|shares: 40%| OP2[Operator 2<br/>3100 - 18%]
    VB -->|shares: 25%| OP1
    VB -->|shares: 50%| OP2
    VB -->|shares: 25%| OP3[Operator 3<br/>750 - 4%]
    
    OP1 -->|max: 2000| V1A((1575 - 9%))
    OP1 -->|max: 2000| V1B((1575 - 9%))
    OP2 -->|max: 2000| V2A((1550 - 9%))
    OP2 -->|max: 2000| V2B((1550 - 9%))
    OP3 -->|min: 500| V3((750 - 4%))

    style L1 fill:#1e293b,color:#f8fafc,stroke:#334155
    style BVM fill:#3b82f6,color:#fff,stroke:#1d4ed8
    style POA fill:#f97316,color:#fff,stroke:#c2410c
    style POS fill:#22c55e,color:#fff,stroke:#15803d
    style VA fill:#14b8a6,color:#fff,stroke:#0f766e
    style VB fill:#14b8a6,color:#fff,stroke:#0f766e
    style OP1 fill:#eab308,color:#1e293b,stroke:#a16207
    style OP2 fill:#eab308,color:#1e293b,stroke:#a16207
    style OP3 fill:#eab308,color:#1e293b,stroke:#a16207
    style V1A fill:#64748b,color:#fff,stroke:#475569
    style V1B fill:#64748b,color:#fff,stroke:#475569
    style V2A fill:#64748b,color:#fff,stroke:#475569
    style V2B fill:#64748b,color:#fff,stroke:#475569
    style V3 fill:#64748b,color:#fff,stroke:#475569
```


### Stake Capacity Subdivision (Single Path)

Following one path through the system to show how caps nest inside each other:

```
L1 TOTAL (100%)
├─────────────────────────────────────────────────────────────────────┐
│ PoS Module (40%)                                                    │
│ ├─────────────────────────────────────────────────────────────────┐ │
│ │ Vault A - L1 cap: 5000 (ceiling, not in calc)                   │ │
│ │ ├─────────────────────────────────────────────────────────────┐ │ │
│ │ │ curator cap: 4000 (23% of L1)                               │ │ │
│ │ │ ├─────────────────────────────────────────────────────────┐ │ │ │
│ │ │ │ Operator 1: 60% → 2400 (14% of L1)                      │ │ │ │
│ │ │ │ ├─────────────────────────────────────────────────────┐ │ │ │ │
│ │ │ │ │ Validator: min 500 (3%) / max 2000 (11%)            │ │ │ │ │
│ │ │ │ │ ├─────────────────────────────────────────────────┐ │ │ │ │ │
│ │ │ │ │ │ 1575 (9% of L1)                                 │ │ │ │ │ │
│ │ │ │ │ └─────────────────────────────────────────────────┘ │ │ │ │ │
│ │ │ │ └─────────────────────────────────────────────────────┘ │ │ │ │
│ │ │ └─────────────────────────────────────────────────────────┘ │ │ │
│ │ │ (unused: 1000)                                              │ │ │
│ │ └─────────────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

**Reading from outside in:**
1. L1 accepts 100% of available stake
2. PoS Module gets 40% allocation from Balancer
3. Vault A's L1 cap = 5000 (ceiling only - not used in stake calc)
4. Vault A's curator cap = 4000 → this IS used in calc → **23%** of L1
5. Operator 1 gets 60% of curator cap = 2400 → **14%** of L1
6. Validator limited by max: 2000 → gets 1575 → **9%** of L1

**% calculation:** All percentages are relative to total curator caps (7000) × PoS allocation (40%).

---

## Variable Reference

| Level | Variable | Constrains | Set By |
|-------|----------|------------|--------|
| Balancer | `maximumChurnPercentage` | Rate of weight changes | Balancer owner |
| Balancer | `securityModuleMaxWeight` | Max weight per module (%) | Balancer owner |
| Vault | `maxL1Limit` / "L1 cap" | Ceiling for vault stake | Middleware owner |
| Vault | `l1Limit` / "curator cap" | Actual stake limit (≤ L1 cap) | Curator |
| Vault | `depositLimit` | Max collateral in vault | Vault admin |
| Operator | `operatorL1Shares` | % share of curator cap | Curator |
| Validator | `minValidatorStake` | Min stake per validator | Middleware |
| Validator | `maxValidatorStake` | Max stake per validator | Middleware |
| Rewards | `minRequiredUptime` | Rewards eligibility | Rewards manager |

---

## Related Documentation

- [Vault Documentation](./3-vault.md) - Deposit limits and vault mechanics
- [Middleware Documentation](./4-middleware.md) - Operator and validator management
- [BalancerValidatorManager](../lib/suzaku-contracts-library/src/contracts/ValidatorManager/README.md) - Security module weight limits
- [Overview](./1-overview.md) - Protocol architecture 
