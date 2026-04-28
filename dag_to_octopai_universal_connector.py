"""
dag_to_octopai_universal_connector.py
======================================
Auto-discovers ALL Airflow DAG (.py) files in the same folder as this script,
parses them via AST + regex pattern matching, then generates Cloudera Octopai
Universal Connector CSV files.

No hardcoding per DAG needed. Just drop DAG files in the same folder and run.

Output (written to same folder):
  - universal-connector-links.csv
  - universal-connector-objects.csv

Usage:
  python dag_to_octopai_universal_connector.py [--dag-dir /path/to/dags] [--out-dir /path/to/output]

Spec:
  https://docs.cloudera.com/octopai/latest/howto/topics/oct-enhancing-data-connectivity-octopais-universal.html
"""

import ast
import csv
import os
import re
import sys
import argparse
import textwrap
from dataclasses import dataclass
from typing import List, Optional, Tuple, Dict

# =============================================================================
# OUTPUT SCHEMA
# =============================================================================

LINKS_COLUMNS = [
    "Process Name", "Process Path", "Process Type", "Process Description",
    "Task Name", "Task Path",
    "Source Provider Name", "Source Component", "Source Server",
    "Source Database", "Source Schema", "Source Object", "Source Column",
    "Source Data Type", "Source Precision", "Source Scale", "Source Object Type",
    "Target Provider Name", "Target Component", "Target Server",
    "Target Database", "Target Schema", "Target Object", "Target Column",
    "Target Data Type", "Target Precision", "Target Scale", "Target Object Type",
    "Expression", "Link Type", "Link Description",
]

OBJECTS_COLUMNS = [
    "Provider Name", "Server Name", "Database Name", "Schema Name",
    "Object Name", "Object Description",
    "Column Name", "Column Description",
    "Data Type", "Is Nullable", "Precision", "Scale", "Object Type",
]


# =============================================================================
# DATA MODELS
# =============================================================================

@dataclass
class LinkRow:
    process_name: str = ""
    process_path: str = ""
    process_type: str = "Airflow DAG"
    process_description: str = ""
    task_name: str = ""
    task_path: str = ""
    source_provider_name: str = ""
    source_component: str = ""
    source_server: str = ""
    source_database: str = ""
    source_schema: str = ""
    source_object: str = ""
    source_column: str = "*"
    source_data_type: str = ""
    source_precision: str = ""
    source_scale: str = ""
    source_object_type: str = ""
    target_provider_name: str = ""
    target_component: str = ""
    target_server: str = ""
    target_database: str = ""
    target_schema: str = ""
    target_object: str = ""
    target_column: str = "*"
    target_data_type: str = ""
    target_precision: str = ""
    target_scale: str = ""
    target_object_type: str = ""
    expression: str = ""
    link_type: str = "DataFlow"
    link_description: str = ""

    def to_dict(self) -> dict:
        return dict(zip(LINKS_COLUMNS, [
            self.process_name, self.process_path, self.process_type,
            self.process_description, self.task_name, self.task_path,
            self.source_provider_name, self.source_component, self.source_server,
            self.source_database, self.source_schema, self.source_object,
            self.source_column, self.source_data_type, self.source_precision,
            self.source_scale, self.source_object_type,
            self.target_provider_name, self.target_component, self.target_server,
            self.target_database, self.target_schema, self.target_object,
            self.target_column, self.target_data_type, self.target_precision,
            self.target_scale, self.target_object_type,
            self.expression, self.link_type, self.link_description,
        ]))


@dataclass
class ObjectRow:
    provider_name: str = ""
    server_name: str = ""
    database_name: str = ""
    schema_name: str = ""
    object_name: str = ""
    object_description: str = ""
    column_name: str = "*"
    column_description: str = ""
    data_type: str = "STRING"
    is_nullable: str = "Y"
    precision: str = ""
    scale: str = ""
    object_type: str = ""

    def to_dict(self) -> dict:
        return dict(zip(OBJECTS_COLUMNS, [
            self.provider_name, self.server_name, self.database_name,
            self.schema_name, self.object_name, self.object_description,
            self.column_name, self.column_description,
            self.data_type, self.is_nullable, self.precision, self.scale,
            self.object_type,
        ]))

    def key(self) -> tuple:
        return (self.database_name, self.schema_name, self.object_name, self.column_name)


# =============================================================================
# SCHEMA REGISTRY  (shared across all DAGs in the folder)
# Key   : (database, schema, object_name)
# Add entries here as your BigQuery / GCS / DB objects grow.
# =============================================================================

SCHEMA_REGISTRY: Dict[Tuple[str, str, str], dict] = {

    # ---- BigQuery: permkt dataset ----------------------------------------
    ("dsi-projects-493408", "permkt", "permkt_stg_leads"): {
        "provider": "BigQuery",
        "server": "bigquery.googleapis.com",
        "object_type": "TABLE",
        "description": "Staging table – permkt leads (truncated each run)",
        "columns": [
            ("record_id",   "STRING",    "N", "Unique lead identifier"),
            ("email",       "STRING",    "Y", "Lead email address"),
            ("full_name",   "STRING",    "Y", "Lead full name"),
            ("phone",       "STRING",    "Y", "Lead phone number"),
            ("source",      "STRING",    "Y", "Marketing source channel"),
            ("campaign_id", "STRING",    "Y", "Campaign identifier"),
            ("lead_date",   "DATE",      "Y", "Lead creation date"),
            ("status",      "STRING",    "Y", "Current lead status"),
            ("updated_at",  "TIMESTAMP", "N", "Row last updated timestamp"),
        ],
    },
    ("dsi-projects-493408", "permkt", "permkt_leads"): {
        "provider": "BigQuery",
        "server": "bigquery.googleapis.com",
        "object_type": "TABLE",
        "description": "Final deduplicated leads table",
        "columns": [
            ("record_id",   "STRING",    "N", "Unique lead identifier (merge key)"),
            ("email",       "STRING",    "Y", "Lead email address"),
            ("full_name",   "STRING",    "Y", "Lead full name"),
            ("phone",       "STRING",    "Y", "Lead phone number"),
            ("source",      "STRING",    "Y", "Marketing source channel"),
            ("campaign_id", "STRING",    "Y", "Campaign identifier"),
            ("lead_date",   "DATE",      "Y", "Lead creation date"),
            ("status",      "STRING",    "Y", "Current lead status"),
            ("updated_at",  "TIMESTAMP", "N", "Timestamp of last upsert"),
        ],
    },

    # ---- GCS bucket: permkt ----------------------------------------------
    ("permkt-gcs", "permkt", "unprocessed"): {
        "provider": "GCS",
        "server": "storage.googleapis.com",
        "object_type": "FILE",
        "description": "GCS landing zone – raw CSV files from proxy",
        "columns": [
            ("record_id",   "STRING", "N", "Unique identifier"),
            ("email",       "STRING", "Y", "Lead email"),
            ("full_name",   "STRING", "Y", "Lead full name"),
            ("phone",       "STRING", "Y", "Lead phone"),
            ("source",      "STRING", "Y", "Source channel"),
            ("campaign_id", "STRING", "Y", "Campaign ID"),
            ("lead_date",   "STRING", "Y", "Lead date (raw CSV string)"),
            ("status",      "STRING", "Y", "Lead status"),
        ],
    },

    # ---- Local filesystem: proxy server ----------------------------------
    ("local-proxy", "filesystem", "unprocessed"): {
        "provider": "LocalFilesystem",
        "server": "permkt-proxy-server",
        "object_type": "FILE",
        "description": "Local unprocessed folder on proxy server (/home/permkt/unprocessed)",
        "columns": [
            ("record_id",   "STRING", "N", "Unique identifier"),
            ("email",       "STRING", "Y", "Lead email"),
            ("full_name",   "STRING", "Y", "Lead full name"),
            ("phone",       "STRING", "Y", "Lead phone"),
            ("source",      "STRING", "Y", "Source channel"),
            ("campaign_id", "STRING", "Y", "Campaign ID"),
            ("lead_date",   "STRING", "Y", "Lead date"),
            ("status",      "STRING", "Y", "Lead status"),
        ],
    },

    # ---- Add more objects below as needed --------------------------------
    # Example: another BigQuery table
    # ("my-project", "my_dataset", "my_table"): {
    #     "provider": "BigQuery",
    #     "server": "bigquery.googleapis.com",
    #     "object_type": "TABLE",
    #     "description": "...",
    #     "columns": [
    #         ("col1", "STRING", "N", "description"),
    #     ],
    # },
}


# =============================================================================
# PROVIDER INFERENCE HELPERS
# Maps keywords found in DAG source code → Octopai provider metadata
# =============================================================================

PROVIDER_MAP = [
    # (keyword_pattern,  provider_name,    server_template,             obj_type)
    (r"bigquery",        "BigQuery",        "bigquery.googleapis.com",   "TABLE"),
    (r"gcs|GCSHook|google\.cloud\.storage", "GCS", "storage.googleapis.com", "FILE"),
    (r"postgres|postgresql", "PostgreSQL",  "{server}",                  "TABLE"),
    (r"mysql",           "MySQL",           "{server}",                  "TABLE"),
    (r"mssql|sqlserver", "SQL Server",      "{server}",                  "TABLE"),
    (r"redshift",        "Redshift",        "{server}",                  "TABLE"),
    (r"snowflake",       "Snowflake",       "{server}",                  "TABLE"),
    (r"s3|boto3",        "S3",              "s3.amazonaws.com",          "FILE"),
    (r"LocalFilesystem|shutil|os\.path",
                         "LocalFilesystem", "localhost",                 "FILE"),
]


def infer_provider(text: str) -> Tuple[str, str, str]:
    """Return (provider_name, server, object_type) from a block of source text."""
    for pattern, provider, server, obj_type in PROVIDER_MAP:
        if re.search(pattern, text, re.IGNORECASE):
            return provider, server, obj_type
    return "Unknown", "", "TABLE"


# =============================================================================
# AST UTILITIES
# =============================================================================

def ast_get_str(node) -> Optional[str]:
    """Safely extract a string constant from an AST node."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):          # f-string → skip
        return None
    return None


def ast_get_keyword(call: ast.Call, name: str) -> Optional[str]:
    """Get a keyword argument string value from a Call node."""
    for kw in call.keywords:
        if kw.arg == name:
            return ast_get_str(kw.value)
    return None


def resolve_fstring(node, var_map: dict) -> str:
    """
    Best-effort resolution of f-strings / Name references using var_map.
    Returns a string like '{PROJECT}.{DATASET}.{TABLE}' or the resolved value.
    """
    if isinstance(node, ast.Constant):
        return str(node.value)
    if isinstance(node, ast.Name) and node.id in var_map:
        return str(var_map[node.id])
    if isinstance(node, ast.JoinedStr):
        parts = []
        for v in node.values:
            if isinstance(v, ast.Constant):
                parts.append(str(v.value))
            elif isinstance(v, ast.FormattedValue):
                parts.append(resolve_fstring(v.value, var_map))
            else:
                parts.append("?")
        return "".join(parts)
    if isinstance(node, ast.Attribute):
        return f"{resolve_fstring(node.value, var_map)}.{node.attr}"
    return "?"


def collect_module_vars(tree: ast.Module) -> dict:
    """
    Walk module-level assignments and collect simple string/int constants
    into a dict  {name: value}.  Useful for resolving PROJECT_ID, DATASET, etc.
    """
    var_map = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    val = ast_get_str(node.value)
                    if val:
                        var_map[target.id] = val
    return var_map


# =============================================================================
# PATTERN DETECTORS
# Each returns (source_info, target_info, task_description) or None.
#
# source_info / target_info are dicts with keys:
#   provider, server, database, schema, object, object_type, component
# =============================================================================

def _bq_table_ref(config_dict: dict, var_map: dict) -> Optional[dict]:
    """
    Parse a BigQuery destinationTable / sourceTable dict from a job config AST.
    Returns {database, schema, object} or None.
    """
    # Walk the dict looking for destinationTable / sourceTable
    def find_key(d: dict, key: str):
        if key in d:
            return d[key]
        for v in d.values():
            if isinstance(v, dict):
                result = find_key(v, key)
                if result is not None:
                    return result
        return None

    for tbl_key in ("destinationTable", "sourceTable"):
        tbl = find_key(config_dict, tbl_key)
        if tbl and isinstance(tbl, dict):
            project = tbl.get("projectId", "")
            dataset = tbl.get("datasetId", "")
            table   = tbl.get("tableId", "")
            return {"database": project, "schema": dataset, "object": table}
    return None


def _parse_bq_job_config(node: ast.Dict, var_map: dict) -> dict:
    """
    Recursively parse a BigQueryInsertJobOperator configuration dict.
    Returns a plain Python dict with string keys/values (best-effort).
    """
    result = {}
    for k, v in zip(node.keys, node.values):
        key = ast_get_str(k) if k else None
        if key is None:
            continue
        if isinstance(v, ast.Dict):
            result[key] = _parse_bq_job_config(v, var_map)
        elif isinstance(v, ast.List):
            result[key] = [resolve_fstring(el, var_map) for el in v.elts]
        else:
            result[key] = resolve_fstring(v, var_map)
    return result


# =============================================================================
# MAIN DAG PARSER
# =============================================================================

class DAGParser:
    """
    Parses a single Airflow DAG .py file via AST and produces
    (links, objects) for Octopai Universal Connector.
    """

    def __init__(self, filepath: str):
        self.filepath = filepath
        self.filename = os.path.basename(filepath)
        self.dag_id   = os.path.splitext(self.filename)[0]
        self.source   = open(filepath, encoding="utf-8").read()
        self.tree     = ast.parse(self.source)
        self.var_map  = collect_module_vars(self.tree)
        self.links: List[LinkRow]    = []
        self.objects: List[ObjectRow] = []

    # ------------------------------------------------------------------
    # ENTRY POINT
    # ------------------------------------------------------------------

    def parse(self) -> Tuple[List[LinkRow], List[ObjectRow]]:
        """Walk all operator instantiation calls in the DAG."""
        for node in ast.walk(self.tree):
            if not isinstance(node, ast.Call):
                continue
            op_name = self._call_name(node)
            if op_name is None:
                continue

            # Route to the appropriate handler
            if "BigQueryInsertJobOperator" in op_name:
                self._handle_bq_insert_job(node)
            elif "BigQueryExecuteQueryOperator" in op_name or "BigQueryOperator" in op_name:
                self._handle_bq_query(node)
            elif "GCSToBigQueryOperator" in op_name:
                self._handle_gcs_to_bq(node)
            elif "BigQueryToGCSOperator" in op_name:
                self._handle_bq_to_gcs(node)
            elif "PostgresOperator" in op_name or "MySqlOperator" in op_name \
                    or "MsSqlOperator" in op_name:
                self._handle_sql_operator(node, op_name)
            elif "S3ToGCSOperator" in op_name:
                self._handle_s3_to_gcs(node)
            elif "PythonOperator" in op_name:
                self._handle_python_operator(node)

        return self.links, self.objects

    # ------------------------------------------------------------------
    # CALL NAME HELPER
    # ------------------------------------------------------------------

    @staticmethod
    def _call_name(node: ast.Call) -> Optional[str]:
        if isinstance(node.func, ast.Name):
            return node.func.id
        if isinstance(node.func, ast.Attribute):
            return node.func.attr
        return None

    # ------------------------------------------------------------------
    # TASK ID HELPER
    # ------------------------------------------------------------------

    def _task_id(self, node: ast.Call) -> str:
        tid = ast_get_keyword(node, "task_id")
        return tid or "unknown_task"

    # ------------------------------------------------------------------
    # SCHEMA REGISTRY LOOKUP
    # ------------------------------------------------------------------

    def _lookup(self, database: str, schema: str, obj: str) -> Optional[dict]:
        """Case-insensitive lookup in SCHEMA_REGISTRY."""
        key = (database, schema, obj)
        if key in SCHEMA_REGISTRY:
            return SCHEMA_REGISTRY[key]
        # Try lower-case match
        for k, v in SCHEMA_REGISTRY.items():
            if (k[0].lower() == database.lower()
                    and k[1].lower() == schema.lower()
                    and k[2].lower() == obj.lower()):
                return v
        return None

    # ------------------------------------------------------------------
    # EMIT HELPERS
    # ------------------------------------------------------------------

    def _emit_link(self, task_id: str, src: dict, tgt: dict, desc: str = "", expr: str = ""):
        """Create one LinkRow per column-pair (or '*' if no schema known)."""
        src_meta = self._lookup(src.get("database",""), src.get("schema",""), src.get("object",""))
        tgt_meta = self._lookup(tgt.get("database",""), tgt.get("schema",""), tgt.get("object",""))

        # Determine column pairs
        if src_meta and tgt_meta:
            src_cols = {c[0]: c for c in src_meta["columns"]}
            tgt_cols = {c[0]: c for c in tgt_meta["columns"]}
            shared   = [c for c in src_cols if c in tgt_cols]
            if not shared:
                shared = list(src_cols.keys())   # emit all src columns
            col_pairs = [(c, src_cols[c], tgt_cols.get(c, src_cols[c])) for c in shared]
        else:
            col_pairs = None   # emit single wildcard row

        if col_pairs:
            for col_name, src_col, tgt_col in col_pairs:
                col_expr = expr
                if col_name == "updated_at" and not col_expr:
                    col_expr = "CURRENT_TIMESTAMP()"
                self.links.append(LinkRow(
                    process_name        = self.dag_id,
                    process_path        = f"airflow/dags/{self.filename}",
                    process_description = f"Airflow DAG: {self.dag_id}",
                    task_name           = task_id,
                    task_path           = f"airflow/dags/{self.filename}/{task_id}",
                    source_provider_name= src.get("provider", src_meta["provider"] if src_meta else ""),
                    source_component    = src.get("component", src.get("object", "")),
                    source_server       = src.get("server", src_meta["server"] if src_meta else ""),
                    source_database     = src.get("database", ""),
                    source_schema       = src.get("schema", ""),
                    source_object       = src.get("object", ""),
                    source_column       = col_name,
                    source_data_type    = src_col[1],
                    source_object_type  = src.get("object_type", src_meta["object_type"] if src_meta else ""),
                    target_provider_name= tgt.get("provider", tgt_meta["provider"] if tgt_meta else ""),
                    target_component    = tgt.get("component", tgt.get("object", "")),
                    target_server       = tgt.get("server", tgt_meta["server"] if tgt_meta else ""),
                    target_database     = tgt.get("database", ""),
                    target_schema       = tgt.get("schema", ""),
                    target_object       = tgt.get("object", ""),
                    target_column       = col_name,
                    target_data_type    = tgt_col[1],
                    target_object_type  = tgt.get("object_type", tgt_meta["object_type"] if tgt_meta else ""),
                    expression          = col_expr,
                    link_description    = desc,
                ))
        else:
            # Wildcard row when no schema known
            self.links.append(LinkRow(
                process_name        = self.dag_id,
                process_path        = f"airflow/dags/{self.filename}",
                process_description = f"Airflow DAG: {self.dag_id}",
                task_name           = task_id,
                task_path           = f"airflow/dags/{self.filename}/{task_id}",
                source_provider_name= src.get("provider", ""),
                source_component    = src.get("component", src.get("object", "")),
                source_server       = src.get("server", ""),
                source_database     = src.get("database", ""),
                source_schema       = src.get("schema", ""),
                source_object       = src.get("object", ""),
                source_column       = "*",
                source_object_type  = src.get("object_type", ""),
                target_provider_name= tgt.get("provider", ""),
                target_component    = tgt.get("component", tgt.get("object", "")),
                target_server       = tgt.get("server", ""),
                target_database     = tgt.get("database", ""),
                target_schema       = tgt.get("schema", ""),
                target_object       = tgt.get("object", ""),
                target_column       = "*",
                target_object_type  = tgt.get("object_type", ""),
                expression          = expr,
                link_description    = desc,
            ))

    def _emit_objects(self, database: str, schema: str, obj_name: str,
                      provider: str = "", server: str = "", object_type: str = ""):
        """Register all columns for an object from SCHEMA_REGISTRY, or a single wildcard row."""
        meta = self._lookup(database, schema, obj_name)
        if meta:
            for col_name, data_type, nullable, col_desc in meta["columns"]:
                self.objects.append(ObjectRow(
                    provider_name   = provider or meta["provider"],
                    server_name     = server   or meta["server"],
                    database_name   = database,
                    schema_name     = schema,
                    object_name     = obj_name,
                    object_description = meta["description"],
                    column_name     = col_name,
                    column_description = col_desc,
                    data_type       = data_type,
                    is_nullable     = nullable,
                    object_type     = object_type or meta["object_type"],
                ))
        else:
            # Emit a wildcard row so the object still appears in Octopai
            self.objects.append(ObjectRow(
                provider_name = provider,
                server_name   = server,
                database_name = database,
                schema_name   = schema,
                object_name   = obj_name,
                object_type   = object_type,
            ))

    # ------------------------------------------------------------------
    # OPERATOR HANDLERS
    # ------------------------------------------------------------------

    def _handle_bq_insert_job(self, node: ast.Call):
        """
        BigQueryInsertJobOperator – handles both LOAD (GCS→BQ) and QUERY jobs.
        """
        task_id = self._task_id(node)

        # Find the 'configuration' keyword argument (an AST dict)
        config_node = None
        for kw in node.keywords:
            if kw.arg == "configuration" and isinstance(kw.value, ast.Dict):
                config_node = kw.value
                break
        if config_node is None:
            return

        config = _parse_bq_job_config(config_node, self.var_map)

        # ---- LOAD job -------------------------------------------------------
        if "load" in config:
            load = config["load"]
            src_uris = load.get("sourceUris", [])
            src_uri  = src_uris[0] if src_uris else ""

            # Parse gs://bucket/prefix → database=bucket-gcs, schema=bucket, object=prefix_stem
            gcs_src = self._parse_gcs_uri(src_uri)

            tbl = load.get("destinationTable", {})
            tgt = {
                "provider":     "BigQuery",
                "server":       "bigquery.googleapis.com",
                "database":     tbl.get("projectId", ""),
                "schema":       tbl.get("datasetId", ""),
                "object":       tbl.get("tableId", ""),
                "object_type":  "TABLE",
            }

            self._emit_link(task_id, gcs_src, tgt,
                            desc=f"CSV LOAD from GCS to BigQuery [{task_id}]")
            self._emit_objects(**{k: gcs_src[k] for k in ("database","schema")},
                               obj_name=gcs_src["object"],
                               provider=gcs_src["provider"],
                               server=gcs_src["server"],
                               object_type=gcs_src["object_type"])
            self._emit_objects(tgt["database"], tgt["schema"], tgt["object"],
                               provider=tgt["provider"], server=tgt["server"],
                               object_type=tgt["object_type"])

        # ---- QUERY job ------------------------------------------------------
        elif "query" in config:
            sql = config["query"].get("query", "")
            self._handle_sql_lineage(task_id, sql,
                                     desc=f"BigQuery SQL [{task_id}]")

    def _handle_bq_query(self, node: ast.Call):
        task_id = self._task_id(node)
        sql_node = None
        for kw in node.keywords:
            if kw.arg == "sql":
                sql_node = kw.value
                break
        if sql_node:
            sql = resolve_fstring(sql_node, self.var_map)
            self._handle_sql_lineage(task_id, sql, desc=f"BigQuery SQL [{task_id}]")

    def _handle_gcs_to_bq(self, node: ast.Call):
        task_id = self._task_id(node)
        bucket  = ast_get_keyword(node, "bucket") or ""
        src_obj = ast_get_keyword(node, "source_objects") or ""
        gcs_src = self._parse_gcs_uri(f"gs://{bucket}/{src_obj}")

        dest_project = (ast_get_keyword(node, "destination_project_dataset_table") or "")
        # format: project.dataset.table
        parts = dest_project.replace(":", ".").split(".")
        tgt = {
            "provider":    "BigQuery",
            "server":      "bigquery.googleapis.com",
            "database":    parts[0] if len(parts) > 2 else "",
            "schema":      parts[1] if len(parts) > 1 else parts[0],
            "object":      parts[-1],
            "object_type": "TABLE",
        }
        self._emit_link(task_id, gcs_src, tgt, desc=f"GCS to BQ [{task_id}]")
        self._emit_objects(**{k: gcs_src[k] for k in ("database","schema")},
                           obj_name=gcs_src["object"],
                           provider=gcs_src["provider"], server=gcs_src["server"],
                           object_type=gcs_src["object_type"])
        self._emit_objects(tgt["database"], tgt["schema"], tgt["object"],
                           provider=tgt["provider"], server=tgt["server"],
                           object_type=tgt["object_type"])

    def _handle_bq_to_gcs(self, node: ast.Call):
        task_id = self._task_id(node)
        src_tbl  = ast_get_keyword(node, "source_project_dataset_table") or ""
        parts    = src_tbl.replace(":", ".").split(".")
        src = {
            "provider":    "BigQuery",
            "server":      "bigquery.googleapis.com",
            "database":    parts[0] if len(parts) > 2 else "",
            "schema":      parts[1] if len(parts) > 1 else parts[0],
            "object":      parts[-1],
            "object_type": "TABLE",
        }
        dest_bucket = ast_get_keyword(node, "destination_cloud_storage_uris") or ""
        tgt = self._parse_gcs_uri(dest_bucket)
        self._emit_link(task_id, src, tgt, desc=f"BQ to GCS export [{task_id}]")
        self._emit_objects(src["database"], src["schema"], src["object"],
                           provider=src["provider"], server=src["server"],
                           object_type=src["object_type"])
        self._emit_objects(**{k: tgt[k] for k in ("database","schema")},
                           obj_name=tgt["object"], provider=tgt["provider"],
                           server=tgt["server"], object_type=tgt["object_type"])

    def _handle_s3_to_gcs(self, node: ast.Call):
        task_id    = self._task_id(node)
        s3_bucket  = ast_get_keyword(node, "bucket") or ""
        s3_prefix  = ast_get_keyword(node, "prefix") or ""
        gcs_bucket = ast_get_keyword(node, "dest_gcs") or ""

        src = {
            "provider": "S3", "server": "s3.amazonaws.com",
            "database": s3_bucket, "schema": "s3", "object": s3_prefix or "data",
            "object_type": "FILE",
        }
        tgt = self._parse_gcs_uri(gcs_bucket or f"gs://{gcs_bucket}/")
        self._emit_link(task_id, src, tgt, desc=f"S3 to GCS copy [{task_id}]")

    def _handle_sql_operator(self, node: ast.Call, op_name: str):
        """Generic SQL operator (Postgres, MySQL, MsSQL)."""
        task_id = self._task_id(node)
        sql_node = None
        for kw in node.keywords:
            if kw.arg == "sql":
                sql_node = kw.value
                break
        if sql_node:
            sql = resolve_fstring(sql_node, self.var_map)
            provider, server, _ = infer_provider(op_name)
            self._handle_sql_lineage(task_id, sql,
                                     desc=f"{op_name} SQL [{task_id}]",
                                     default_provider=provider,
                                     default_server=server)

    def _handle_python_operator(self, node: ast.Call):
        """
        PythonOperator – infer source/target by inspecting the callable's
        source code for GCS upload / shutil.move / db write patterns.
        """
        task_id   = self._task_id(node)

        # callable may be passed as keyword OR positional
        callable_ = None
        for kw in node.keywords:
            if kw.arg == "python_callable":
                if isinstance(kw.value, ast.Name):
                    callable_ = kw.value.id
                elif isinstance(kw.value, ast.Constant):
                    callable_ = kw.value.value
                break

        # Find the function definition in the module
        func_src = self._find_function_source(callable_)
        if func_src is None:
            # Try scanning the whole file as fallback
            func_src = self.source

        # Classify using full file source (callable may delegate to helper functions)
        full_ctx = func_src + "\n" + self.source
        is_gcs_upload = bool(re.search(r"upload_to_gcs|blob\.upload|storage\.Client", full_ctx))
        is_local_move = bool(re.search(r"shutil\.move|shutil\.copy|os\.rename", full_ctx))
        is_gcs_move   = bool(re.search(r"GCSHook|hook\.copy|hook\.delete", full_ctx))

        # --- Local → GCS upload ---
        if is_gcs_upload:
            src = {
                "provider": "LocalFilesystem", "server": "permkt-proxy-server",
                "database": "local-proxy",     "schema": "filesystem",
                "object":   "unprocessed",     "object_type": "FILE",
                "component": "/home/permkt/unprocessed",
            }
            tgt = {
                "provider": "GCS",             "server": "storage.googleapis.com",
                "database": "permkt-gcs",      "schema": "permkt",
                "object":   "unprocessed",     "object_type": "FILE",
                "component": "gs://permkt/unprocessed",
            }
            self._emit_link(task_id, src, tgt,
                            desc=f"Python: upload CSV from local to GCS [{task_id}]")
            self._emit_objects("local-proxy",  "filesystem", "unprocessed",
                               provider="LocalFilesystem", server="permkt-proxy-server",
                               object_type="FILE")
            self._emit_objects("permkt-gcs", "permkt", "unprocessed",
                               provider="GCS", server="storage.googleapis.com",
                               object_type="FILE")

        # --- GCS folder move (inprocess/processed) ---
        elif is_gcs_move:
            # Extract GCS source/destination from the function source
            src_prefix_m = re.search(r'source\s*=\s*["\']([^"\']+)["\']', func_src)
            tgt_prefix_m = re.search(r'target\s*=\s*["\']([^"\']+)["\']', func_src)
            bucket_m     = re.search(r'BUCKET\s*=\s*["\']([^"\']+)["\']', self.source)

            src_prefix = src_prefix_m.group(1).strip("/") if src_prefix_m else "unprocessed"
            tgt_prefix = tgt_prefix_m.group(1).strip("/") if tgt_prefix_m else "processed"
            bucket     = bucket_m.group(1) if bucket_m else "permkt"

            src = {
                "provider": "GCS", "server": "storage.googleapis.com",
                "database": f"{bucket}-gcs", "schema": bucket,
                "object":   src_prefix, "object_type": "FILE",
            }
            tgt = {
                "provider": "GCS", "server": "storage.googleapis.com",
                "database": f"{bucket}-gcs", "schema": bucket,
                "object":   tgt_prefix, "object_type": "FILE",
            }
            self._emit_link(task_id, src, tgt,
                            desc=f"Python: GCS folder move {src_prefix}→{tgt_prefix} [{task_id}]")

        # --- Fallback: annotate as process-only node ---
        else:
            self.links.append(LinkRow(
                process_name        = self.dag_id,
                process_path        = f"airflow/dags/{self.filename}",
                process_description = f"Airflow DAG: {self.dag_id}",
                task_name           = task_id,
                task_path           = f"airflow/dags/{self.filename}/{task_id}",
                source_column       = "*",
                target_column       = "*",
                link_description    = f"Python callable: {callable_ or 'unknown'} (no I/O pattern detected)",
            ))

    # ------------------------------------------------------------------
    # SQL LINEAGE PARSER
    # ------------------------------------------------------------------

    def _handle_sql_lineage(self, task_id: str, sql: str,
                            desc: str = "",
                            default_provider: str = "BigQuery",
                            default_server: str = "bigquery.googleapis.com"):
        """
        Extract source→target lineage from SQL.
        Handles: INSERT INTO, MERGE, CREATE TABLE AS SELECT, TRUNCATE.
        """
        sql_clean = re.sub(r"--[^\n]*", " ", sql)   # strip line comments
        sql_clean = re.sub(r"/\*.*?\*/", " ", sql_clean, flags=re.DOTALL)
        sql_upper = sql_clean.upper()

        # ---- TRUNCATE (no lineage, but register the table) ---------------
        if "TRUNCATE" in sql_upper:
            tbl = self._extract_table_ref(sql_clean, r"TRUNCATE\s+TABLE\s+([`'\"]?[\w.\-]+[`'\"]?)")
            if tbl:
                db, schema, obj = tbl
                self._emit_objects(db, schema, obj,
                                   provider=default_provider, server=default_server,
                                   object_type="TABLE")
            return

        # ---- MERGE --------------------------------------------------------
        if "MERGE" in sql_upper:
            merge_tgt = self._extract_table_ref(sql_clean,
                r"MERGE\s+[`'\"]?[\w.\-]+[`'\"]?\s+(\w+)?\s*\n?\s*USING\s*\(",
                group=0,
                pattern2=r"MERGE\s+([`'\"]?[\w.\-]+[`'\"]?)")
            merge_src = self._extract_table_ref(sql_clean,
                r"FROM\s+([`'\"]?[\w.\-]+[`'\"]?)")

            tgt_m = re.search(r"MERGE\s+([`'\"]?[\w.\-]+[`'\"]?)", sql_clean, re.IGNORECASE)
            src_m = re.search(r"FROM\s+([`'\"]?[\w.\-]+[`'\"]?)", sql_clean, re.IGNORECASE)

            if tgt_m and src_m:
                src_db, src_schema, src_obj = self._split_table_ref(src_m.group(1))
                tgt_db, tgt_schema, tgt_obj = self._split_table_ref(tgt_m.group(1))

                src_info = {
                    "provider": default_provider, "server": default_server,
                    "database": src_db, "schema": src_schema, "object": src_obj,
                    "object_type": "TABLE",
                }
                tgt_info = {
                    "provider": default_provider, "server": default_server,
                    "database": tgt_db, "schema": tgt_schema, "object": tgt_obj,
                    "object_type": "TABLE",
                }
                self._emit_link(task_id, src_info, tgt_info, desc=desc,
                                expr="CURRENT_TIMESTAMP() for updated_at")
                self._emit_objects(src_db, src_schema, src_obj,
                                   provider=default_provider, server=default_server,
                                   object_type="TABLE")
                self._emit_objects(tgt_db, tgt_schema, tgt_obj,
                                   provider=default_provider, server=default_server,
                                   object_type="TABLE")
            return

        # ---- INSERT INTO ... SELECT / CREATE TABLE AS SELECT -------------
        for pattern in [
            r"INSERT\s+(?:INTO|OVERWRITE)\s+([`'\"]?[\w.\-]+[`'\"]?)",
            r"CREATE\s+(?:OR\s+REPLACE\s+)?TABLE\s+([`'\"]?[\w.\-]+[`'\"]?)\s+AS",
        ]:
            tgt_m = re.search(pattern, sql_clean, re.IGNORECASE)
            if tgt_m:
                src_m = re.search(r"FROM\s+([`'\"]?[\w.\-]+[`'\"]?)", sql_clean, re.IGNORECASE)
                if src_m:
                    src_db, src_schema, src_obj = self._split_table_ref(src_m.group(1))
                    tgt_db, tgt_schema, tgt_obj = self._split_table_ref(tgt_m.group(1))
                    src_info = {
                        "provider": default_provider, "server": default_server,
                        "database": src_db, "schema": src_schema, "object": src_obj,
                        "object_type": "TABLE",
                    }
                    tgt_info = {
                        "provider": default_provider, "server": default_server,
                        "database": tgt_db, "schema": tgt_schema, "object": tgt_obj,
                        "object_type": "TABLE",
                    }
                    self._emit_link(task_id, src_info, tgt_info, desc=desc)
                    self._emit_objects(src_db, src_schema, src_obj,
                                       provider=default_provider, server=default_server,
                                       object_type="TABLE")
                    self._emit_objects(tgt_db, tgt_schema, tgt_obj,
                                       provider=default_provider, server=default_server,
                                       object_type="TABLE")
                return

    # ------------------------------------------------------------------
    # UTILITY METHODS
    # ------------------------------------------------------------------

    @staticmethod
    def _parse_gcs_uri(uri: str) -> dict:
        """
        Parse a GCS URI like gs://bucket/prefix/object  into lineage fields.
        Wildcards (*.csv) become the object name without the wildcard.
        """
        uri   = uri.strip()
        match = re.match(r"gs://([^/]+)/?(.*)", uri)
        if match:
            bucket = match.group(1)
            path   = match.group(2).rstrip("/*").rstrip("/")
            folder = path.split("/")[0] if path else bucket
        else:
            bucket = uri
            folder = "data"
        return {
            "provider":    "GCS",
            "server":      "storage.googleapis.com",
            "database":    f"{bucket}-gcs",
            "schema":      bucket,
            "object":      folder or bucket,
            "object_type": "FILE",
            "component":   uri,
        }

    @staticmethod
    def _split_table_ref(ref: str) -> Tuple[str, str, str]:
        """
        Split a table reference like `project.dataset.table` or `dataset.table`
        into (database, schema, object).  Strips backticks and quotes.
        """
        ref = ref.strip("`'\"")
        parts = ref.split(".")
        if len(parts) >= 3:
            return parts[0], parts[1], parts[2]
        if len(parts) == 2:
            return "", parts[0], parts[1]
        return "", "", parts[0]

    def _extract_table_ref(self, sql: str, pattern: str,
                           group: int = 1, pattern2: str = None) -> Optional[Tuple]:
        m = re.search(pattern, sql, re.IGNORECASE | re.DOTALL)
        if not m and pattern2:
            m = re.search(pattern2, sql, re.IGNORECASE)
        if m:
            ref = m.group(group if group > 0 else 1)
            return self._split_table_ref(ref)
        return None

    def _find_function_source(self, func_name: Optional[str]) -> Optional[str]:
        """Return source lines of a top-level function definition by name."""
        if not func_name:
            return None
        for node in ast.walk(self.tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name == func_name:
                    lines = self.source.splitlines()
                    return "\n".join(lines[node.lineno - 1: node.end_lineno])
        return None


# =============================================================================
# FOLDER SCANNER
# =============================================================================

def is_dag_file(filepath: str) -> bool:
    """Heuristic: .py file that references 'DAG' or 'dag_id'."""
    try:
        content = open(filepath, encoding="utf-8", errors="ignore").read(4096)
        return bool(re.search(r"\bDAG\b|\bdag_id\b", content))
    except Exception:
        return False


def scan_folder(dag_dir: str) -> List[str]:
    """Return all .py files in dag_dir that look like Airflow DAGs."""
    found = []
    for fname in sorted(os.listdir(dag_dir)):
        if fname.endswith(".py") and not fname.startswith("__"):
            fpath = os.path.join(dag_dir, fname)
            # Skip self
            if os.path.abspath(fpath) == os.path.abspath(__file__):
                continue
            if is_dag_file(fpath):
                found.append(fpath)
    return found


# =============================================================================
# DEDUPLICATION
# =============================================================================

def deduplicate_objects(rows: List[ObjectRow]) -> List[ObjectRow]:
    seen, result = set(), []
    for row in rows:
        k = row.key()
        if k not in seen:
            seen.add(k)
            result.append(row)
    return result


def deduplicate_links(rows: List[LinkRow]) -> List[LinkRow]:
    seen, result = set(), []
    for row in rows:
        k = (row.process_name, row.task_name,
             row.source_database, row.source_schema, row.source_object, row.source_column,
             row.target_database, row.target_schema, row.target_object, row.target_column)
        if k not in seen:
            seen.add(k)
            result.append(row)
    return result


# =============================================================================
# CSV WRITER
# =============================================================================

def write_csv(filepath: str, columns: List[str], rows: List[dict]):
    with open(filepath, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    print(f"  ✔  {len(rows):>4} rows  →  {filepath}")


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Convert Airflow DAG folder → Octopai Universal Connector CSVs"
    )
    parser.add_argument(
        "--dag-dir", default=None,
        help="Folder containing DAG .py files (default: same folder as this script)"
    )
    parser.add_argument(
        "--out-dir", default=None,
        help="Output folder for CSVs (default: same as --dag-dir)"
    )
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    dag_dir    = os.path.abspath(args.dag_dir) if args.dag_dir else script_dir
    out_dir    = os.path.abspath(args.out_dir) if args.out_dir else dag_dir

    os.makedirs(out_dir, exist_ok=True)

    print("\n" + "=" * 65)
    print("  Octopai Universal Connector – Auto DAG Converter")
    print("=" * 65)
    print(f"  DAG folder : {dag_dir}")
    print(f"  Output dir : {out_dir}")

    dag_files = scan_folder(dag_dir)
    if not dag_files:
        print("\n  ⚠  No DAG files found. Exiting.")
        sys.exit(0)

    print(f"\n  Found {len(dag_files)} DAG file(s):")
    for f in dag_files:
        print(f"    • {os.path.basename(f)}")

    all_links:   List[LinkRow]   = []
    all_objects: List[ObjectRow] = []

    print()
    for i, fpath in enumerate(dag_files, 1):
        dag_name = os.path.basename(fpath)
        print(f"  [{i}/{len(dag_files)}] Parsing: {dag_name} ...")
        try:
            p = DAGParser(fpath)
            links, objects = p.parse()
            all_links.extend(links)
            all_objects.extend(objects)
            print(f"         → {len(links)} links, {len(objects)} object-column rows")
        except SyntaxError as e:
            print(f"         ✘  Syntax error – skipping ({e})")
        except Exception as e:
            print(f"         ✘  Parse error – skipping ({e})")

    # Dedup
    all_links   = deduplicate_links(all_links)
    all_objects = deduplicate_objects(all_objects)

    links_path   = os.path.join(out_dir, "universal-connector-links.csv")
    objects_path = os.path.join(out_dir, "universal-connector-objects.csv")

    print("\n  Writing output ...")
    write_csv(links_path,   LINKS_COLUMNS,   [r.to_dict() for r in all_links])
    write_csv(objects_path, OBJECTS_COLUMNS, [r.to_dict() for r in all_objects])

    print(f"\n  ─────────────────────────────────────────")
    print(f"  DAGs processed : {len(dag_files)}")
    print(f"  Total links    : {len(all_links)}")
    print(f"  Total objects  : {len(all_objects)}")
    print(f"  ─────────────────────────────────────────")
    print("  Done! Upload the CSV files to Octopai Universal Connector.")
    print("=" * 65 + "\n")


if __name__ == "__main__":
    main()
