# Utility Operations Intelligence — Databricks Demo

End-to-end Databricks demo for a renewable energy utility: structured operational data + 50 unstructured PDF documents, exposed through 3 Genie Spaces + 4 Metric Views, orchestrated by a multi-agent supervisor model, and surfaced through a branded FastAPI web app deployed as a Databricks App.

The demo tells a coherent story — *"emergency vendor costs are escalating in NW-PowerPool because the same problem-assets keep failing and Cascadia is stuck in an emergency-repair cycle with one expensive vendor"* — that can be discovered by an AI from any combination of structured queries and unstructured document retrieval.

## What's in this repo

```
.
├── config.ipynb            #  EDIT THIS — the single place to configure the whole demo
├── utility_ops_demo.ipynb  #  RUN THIS — orchestrator: narrated Steps 1-6, inline UI prompts
├── 1-data/                 # Generate the 13 source tables (~11.5M rows)
│   ├── generate.py / .ipynb
│   └── sanity_sql.py / .ipynb
├── 2-metric-views/         # Build rollups + 4 metric views, validate all 55 measures
│   ├── build_metric_views.py / .ipynb
│   └── test_metric_views.py / .ipynb
├── 3-genie-spaces/         # Create 3 Genie Spaces via REST API
│   └── build_genie_spaces.py / .ipynb
├── 4-documents/            # Narrative bible, prompts, 50 source MD + 50 PDFs
│   ├── NARRATIVE_BIBLE.md
│   ├── anchor_narrative.py / .ipynb
│   ├── source-md/          # 50 source markdown files
│   └── pdfs/               # 50 generated PDFs (ready to upload)
├── 5-supervisor-model/     # UI walkthrough for building the supervisor agent
│   └── README.md
└── 6-app/                  # FastAPI / static UI Databricks App
    ├── app.py              # backend: SSE streaming + in-app Q&A cache
    ├── app.yaml
    ├── deploy_app.ipynb    # create app → GRANT the SP → deploy (grants baked in)
    ├── deploy.sh           # same flow for local/CLI use (create → grant → deploy)
    ├── grant_app_sp.sh     # applies all downstream grants (driven by grants.env)
    ├── grants.env          # the resources the app SP must reach (endpoints, Genie IDs, warehouse, UC)
    ├── requirements.txt
    └── static/             # index.html, style.css, app.js, logo.png (placeholder — replace with your branding)
```

Numbered prefixes are the **deployment order**.

## Fastest path — one config, one orchestrator

The demo is driven by a **single config notebook** and run from a **single orchestrator**, the same
structure as the lakebase-recovery template:

1. Open **`config.ipynb`** and set your environment once (catalog, schema, volume, warehouse ID,
   email). This is the *only* place you edit values — every step reads them via `%run ./config`.
2. Open **`utility_ops_demo.ipynb`** and run top-to-bottom. It narrates and runs each step:
   - **Steps 1-4** (data, metric views, Genie spaces, PDFs) run automatically. Step 3 captures the
     new Genie space IDs back into config.
   - **Steps 5a / 5b** are the two things that *can't* be scripted (Knowledge Assistant + Supervisor
     in Agent Bricks). The orchestrator prints the **exact prompts and values to paste** into the UI,
     and the exact Genie space IDs to add as tools. Paste the resulting endpoint names into `config`.
   - **Step 6** grants the app's service principal on every downstream resource **and then** deploys,
     so the app comes up already authorized.

Total runtime ~30-40 min, dominated by the 10M-row telemetry generation in Step 1.

> **Why Step 6 grants before it deploys.** The app runs as its own service principal, and the
> supervisor calls its tools *as that SP*. If you deploy without granting, the app looks healthy but
> **403s at runtime** on every question. `deploy_app` (and `deploy.sh`) create the app, grant the SP
> `CAN_QUERY`/`CAN_RUN`/`CAN_USE` + UC data access, and only then deploy — the fix is baked in.

Prefer scripts? Every step still has a `.py`/`.sh` equivalent you can `uv run` / `bash` locally; the
config for the CLI deploy path lives in `6-app/grants.env`.

## Architecture

```
                                ┌──────────────────────────────────────┐
                                │  Databricks App (FastAPI + static UI) │
                                │   utility-ops-supervisor              │
                                └─────────────────┬────────────────────┘
                                                  │ POST /api/chat
                                                  ▼
                                ┌──────────────────────────────────────┐
                                │  Supervisor Model Serving Endpoint   │
                                │   mas-cf2369f5-endpoint              │
                                │   (Mosaic AI Agent Framework)        │
                                └─┬────────┬───────────────┬───────────┘
                                  │        │               │
            ┌─────────────────────┘        │               └─────────────────────┐
            ▼                              ▼                                     ▼
  ┌──────────────────┐         ┌──────────────────────┐              ┌────────────────────────┐
  │  3 Genie Spaces  │         │  4 UC Metric Views   │              │ Knowledge Assistant    │
  │  (chat UI tools) │ ◄────── │  grid_operations     │              │ over PDF volume:       │
  │                  │         │  financial_perf      │              │  /Volumes/.../reports  │
  │                  │         │  maintenance_work    │              │   (50 PDFs)            │
  │                  │         │  executive_summary   │              │                        │
  └────────┬─────────┘         └──────────┬───────────┘              └────────────┬───────────┘
           │                              │                                       │
           └──────────────────────────────┴───────────────────────────────────────┘
                                          │
                                          ▼
                              ┌────────────────────────────┐
                              │  Unity Catalog tables (13) │
                              │  + 2 daily rollups         │
                              │  + 50 PDFs in UC Volume    │
                              └────────────────────────────┘
```

## Prerequisites

1. A Databricks workspace with **Unity Catalog**, **Serverless SQL**, **Mosaic AI Agent Framework**, **Genie**, and **Databricks Apps** enabled.
2. A target catalog and schema you can write to.
3. Databricks CLI v0.296+ installed and authenticated.
4. Python 3.12 + [uv](https://github.com/astral-sh/uv) for running the scripts locally.
5. macOS users running the PDF generation step also need WeasyPrint system deps:
   ```bash
   brew install cairo pango gdk-pixbuf libffi glib
   ```

## End-to-end deployment (manual / per-step)

If you prefer to run each step individually (or you're running outside of Databricks):

```bash
# 1. Generate structured operational data
cd 1-data/ && uv run --python 3.12 --with polars --with numpy --with mimesis --with pandas --with 'databricks-connect>=16.4,<17.0' generate.py

# 2. Build rollup tables + 4 metric views
cd ../2-metric-views/ && uv run --python 3.12 --with 'databricks-connect>=16.4,<17.0' build_metric_views.py
uv run --python 3.12 --with 'databricks-connect>=16.4,<17.0' test_metric_views.py

# 3. Create 3 Genie spaces
cd ../3-genie-spaces/ && python3 build_genie_spaces.py
# (follow that folder's README to POST the create payloads via databricks CLI)

# 4. Upload the 50 PDFs to a UC Volume (already in 4-documents/pdfs/)
cd ../4-documents/ && bash convert_and_upload.sh
# (regenerating the PDFs from scratch is optional — see 4-documents/README.md)

# 5. Build the supervisor multi-agent system in the UI
# See 5-supervisor-model/README.md (manual UI steps in Mosaic AI Agent Framework)

# 6. Deploy the app
cd ../6-app/ && bash deploy.sh
```

## App-side features (step 6)

The Databricks App you deploy in step 6 includes:

- **Live streaming** — the supervisor's responses stream to the UI token-by-token as the multi-agent system generates them. Routing pills and the trace panel update as each tool call fires.
- **In-app Q&A cache** — LRU keyed on `(history + question)` hash, 1 hour TTL. Repeat questions return in <1 second with a `⚡ Cached` badge.
- **Async job pattern** — bypasses the Databricks Apps gateway 60s timeout; supports questions up to 10 minutes.
- **Trace inspector** — right-side panel shows the supervisor's reasoning chain: intent → tool routing → tool results → synthesis. Each tool call is color-coded (blue = Genie, green = document RAG).

## Total objects you'll end up with

| Tier | Count | Where |
| --- | --- | --- |
| Source tables | 13 | UC catalog/schema |
| Daily rollup tables | 2 | UC catalog/schema |
| Metric views | 4 | UC catalog/schema |
| Genie spaces | 3 | workspace-level |
| Unstructured docs (PDFs) | 50 | UC Volume `reports/` |
| Supervisor endpoint | 1 | model serving endpoints |
| Knowledge Assistant endpoint | 1 | model serving endpoints |
| Databricks App | 1 | workspace-level |

## Headline data points the AI can discover

- ERCOT had 433 forced outages, the most of any region
- NW-PowerPool generated $8.9M in emergency vendor invoices (4× equivalent CPS scope)
- WIN-10130 (Siemens Gamesa, CAISO-WIND-026) lost 20,494 MWh across 14 outages
- TRA-10561 was emergency-repaired twice by the same vendor 6 months apart
- Siemens Gamesa OEM manual mandates replacement at a vibration threshold lower than internal Standard MS-2025-03 — formal override (MOC-2025-022) pending engineering review for 9+ months

## Notes / known issues

- The narrative bible (`4-documents/NARRATIVE_BIBLE.md`) is the single source of truth for entity names, dates, and dollar values across all documents. Minor inter-document numeric drift exists on the Siemens Gamesa vibration threshold (3.5 vs 4.5 vs 6.0 mm/s across document groups) — direction of the narrative is consistent.
- All structured data is for calendar year 2025. If you need a different year, change `YEAR_START` / `YEAR_END` in `1-data/generate.py`.
- App ships with a placeholder logo (`6-app/static/logo.png` — says "Add Logo Here") and a neutral blue/green palette. Replace the PNG with your branding and edit the CSS variables in `6-app/static/style.css` to rebrand for a specific customer.
