# fabric-item-promote-demo

A sandbox for **[fabric-item-promote](https://github.com/EhsanFabricDev/fabric-item-promote)**:
promote selected Microsoft Fabric items between Git branches, not commits.

The items here are small stand-ins (not connected to a workspace). The branches are set up so
every check fires:

| Branch | State |
|---|---|
| `develop` | Default branch. Has a workspace commit on `Sales_Load` that `feature/sales-refresh` doesn't |
| `test`, `main` | Older copies of `develop` |
| `feature/sales-refresh` | Several changes: `Sales_Load` uses a new helper in `nb_utils`; new `New_Report` notebook that `%run`s a new `nb_report_helpers`; `Ingest_Sales` uses a new library variable |

## Try it

Fork the repo, then Actions → **Promote Fabric items** → Run workflow:

| Copy FROM | Items | What you'll see |
|---|---|---|
| `feature/sales-refresh` | `Sales_Load.Notebook` | PR opened, with ⚠️ "`nb_utils` differs" and ⚠️ "this promotion undoes" the develop commit |
| `feature/sales-refresh` | `New_Report.Notebook` | ❌ Blocked: `nb_report_helpers` isn't on `develop` |
| `feature/sales-refresh` | `New_Report.Notebook, nb_report_helpers.Notebook` | PR opened, clean |
| `feature/sales-refresh` | `Ingest_Sales.DataPipeline` | ❌ Blocked: library variable `sales_connection_id` isn't declared on `develop` |
| `feature/sales-refresh` | `Ingest_Sales.DataPipeline, vl_settings.VariableLibrary` | PR opened |
| `develop` → `main` | `Sales_Load.Notebook` | ❌ Blocked: `main` only receives from `test` |

In a fork, enable *Settings → Actions → General → Allow GitHub Actions to create and approve
pull requests* so the workflow can open PRs.
