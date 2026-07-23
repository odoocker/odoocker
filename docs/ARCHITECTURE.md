# Architecture

## System Topology

```mermaid
graph TB
    subgraph "Internet"
        U1[goldberrygrove.farm]
        U2[woodworkingeorge.com]
        U3[atthegrovenursery.com]
        U4[erp.gatheringatthegrove.com]
    end

    subgraph "DigitalOcean Droplet"
        NP[nginx-proxy :80/:443] --> |TLS termination| N[nginx]
        AC[acme-companion] --> NP

        N --> |catch-all| O[Odoo :8069]
        N --> |blog.goldberrygrove.farm| G1[Ghost Goldberry :2368]
        N --> |blog.woodworkingeorge.com| G2[Ghost GGG :2369]
        N --> |blog.atthegrovenursery.com| G3[Ghost Nursery :2370]

        O --> PG[PostgreSQL :5432]
        O --> KD[KeyDB :6379]
        O --> S3[MinIO :9000]

        GS[git-sync] --> |/workspace/current| O
    end

    U1 --> NP
    U2 --> NP
    U3 --> NP
    U4 --> NP
```

## Data Flow: React Website → Backend

```mermaid
sequenceDiagram
    participant B as Browser
    participant R as React/Next.js (BFF)
    participant O as Odoo API
    participant G as Ghost Content API
    participant K as KeyDB Cache

    B->>R: GET /products
    R->>K: Check cache (grove:products:company_1)
    alt Cache HIT
        K-->>R: Cached product list
    else Cache MISS
        R->>O: /grove/api/v1/products (company_id=1)
        O-->>R: Product JSON
        R->>K: Cache (TTL 5min)
    end
    R-->>B: Product list page

    B->>R: GET /blog
    R->>G: Ghost Content API /posts/
    G-->>R: Blog posts (ISR cached)
    R-->>B: Blog page
```

## Multi-Company Model

```mermaid
graph LR
    subgraph "Single Odoo Database"
        C1[Company 1: Goldberry Grove Farm]
        C2[Company 2: George George George Woodworking, LLC]
        C3[Company 3: At The Grove Nursery, LLC]
    end

    subgraph "Record Rules"
        RR[company_id filter]
    end

    C1 --> |own products, orders, leads| RR
    C2 --> |own products, orders, leads| RR
    C3 --> |own products, orders, leads| RR

    subgraph "Inter-Company"
        IC[Inter-Company Transactions]
    end

    C1 <--> IC
    C2 <--> IC
    C3 <--> IC
```

Each API request includes a company context (derived from the website/domain). Odoo's ORM-level record rules enforce data isolation automatically. Inter-company transactions (e.g., GGG supplies lumber to Goldberry) are handled by Odoo's built-in inter-company module.

## Module Deployment

```mermaid
graph LR
    DEV[Developer pushes to grove-odoo-modules] --> GH[GitHub]
    GH --> |webhook| GS[git-sync container]
    GS --> |updates /workspace/current| O[Odoo reads new code]

    style GS fill:#f9f,stroke:#333
```

No Docker image rebuild needed. Polling interval: 30s. Webhook triggers instant sync.
