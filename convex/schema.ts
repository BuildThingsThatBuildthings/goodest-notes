import {defineSchema,defineTable} from "convex/server";
import {v} from "convex/values";

// Stable notebook IDs are portable across managed and self-hosted instances.
// Scope indexes isolate per-project history, membership, and task queues.
export default defineSchema({ entries:defineTable({
  collection:v.string(), key:v.string(), scope:v.string(), value:v.any()
}).index("by_key",["collection","key"]).index("by_scope",["collection","scope","key"]) });
