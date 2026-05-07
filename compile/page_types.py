from __future__ import annotations


NAV_PAGE_TYPES = {"index", "overview", "log"}
ARTICLE_PAGE_TYPES = {"article", "concept", "entity", "question", "note", "person", "place", "timeline"}
MAP_PAGE_TYPES = {"dashboard", "map"}
OUTPUT_PAGE_TYPES = {"comparison", "output"}
WATCH_PAGE_TYPES = {"watch"}
CONTENT_PAGE_TYPES = ARTICLE_PAGE_TYPES | OUTPUT_PAGE_TYPES
DEFAULT_PAGE_TYPES = {"source", "article", "map", "output", "watch", "index", "overview", "log"}
MATURITY_STATES = {"seed", "emerging", "stable"}
OUTPUT_FORMATS = {"markdown", "marp", "chart", "canvas"}
WATCH_LIFECYCLE_STATES = {"active", "paused", "error"}
WATCH_RUN_STATUSES = {"ok", "failed", "unchanged"}
