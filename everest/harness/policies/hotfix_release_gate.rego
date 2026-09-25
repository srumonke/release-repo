# OPA policy for the Everest hotfix deploy flow.
#
# Create as a Policy (Project Sruthi) named `hotfix_release_gate`, then a POLICY SET with the
# same identifier `hotfix_release_gate`, entity type "Custom", enforced. The Stage 1 `OPA On Run`
# Policy step evaluates it against a custom payload, so the rules see the RUNTIME input from the
# input set — not just the stored pipeline YAML.
#
# Optionally ALSO attach the same policy set to the pipeline with entity type "Pipeline" and
# event "On Run" for a belt-and-braces gate before the first stage even starts. Note that an
# On Run pipeline policy sees `input.pipeline`, not this payload, so it can only read the stored
# variable values — the Policy step is the one that sees what the operator actually submitted.
#
# Expected payload:
#   {
#     "hotfixVersion":   "4.1.3",
#     "services":        "everest_a,everest_b",
#     "serviceVersions": "everest_a=4.1.3,everest_b=4.1.3",
#     "ticket":          "CS-1234"
#   }

package everest

# ---------------------------------------------------------------------------
# Helpers
#
# `clean` rather than `trim`: trim() is an OPA builtin and redefining a builtin
# name is a compile error.
# ---------------------------------------------------------------------------

clean(s) = t {
	t := trim_space(s)
}

declared_services := {clean(s) | s := split(input.services, ",")[_]; clean(s) != ""}

pairs := [clean(p) | p := split(input.serviceVersions, ",")[_]; clean(p) != ""]

# Only well-formed name=version pairs contribute to these two sets. Malformed
# pairs are caught by their own rule below rather than silently vanishing.
mapped_services := {clean(parts[0]) |
	p := pairs[_]
	parts := split(p, "=")
	count(parts) == 2
}

all_versions := {clean(parts[1]) |
	p := pairs[_]
	parts := split(p, "=")
	count(parts) == 2
}

# ---------------------------------------------------------------------------
# The input must be well formed at all.
# ---------------------------------------------------------------------------

deny[msg] {
	count(declared_services) == 0
	msg := "the input set declares no services"
}

deny[msg] {
	p := pairs[_]
	count(split(p, "=")) != 2
	msg := sprintf("%v is not a name=version pair", [p])
}

# ---------------------------------------------------------------------------
# A version must be a RELEASED version. Candidates never reach an environment.
# ---------------------------------------------------------------------------

deny[msg] {
	v := all_versions[_]
	contains(lower(v), "-rc")
	msg := sprintf("version %v is a release candidate, not a released version", [v])
}

deny[msg] {
	v := all_versions[_]
	contains(lower(v), "-snapshot")
	msg := sprintf("version %v is a snapshot, not a released version", [v])
}

deny[msg] {
	v := all_versions[_]
	not regex.match("^[0-9]+\\.[0-9]+\\.[0-9]+$", v)
	msg := sprintf("version %v is not a semantic released version like 4.1.3", [v])
}

# ---------------------------------------------------------------------------
# The whole set must move together, on ONE version, and it must be the version
# the run asked for.
# ---------------------------------------------------------------------------

deny[msg] {
	count(all_versions) > 1
	msg := sprintf("services are not on one version: %v", [all_versions])
}

deny[msg] {
	v := all_versions[_]
	v != input.hotfixVersion
	msg := sprintf("a service is on %v but the run requested hotfix version %v", [v, input.hotfixVersion])
}

# ---------------------------------------------------------------------------
# The set must be complete in both directions.
# ---------------------------------------------------------------------------

deny[msg] {
	s := declared_services[_]
	not mapped_services[s]
	msg := sprintf("declared service %v has no version in the input set", [s])
}

deny[msg] {
	s := mapped_services[_]
	not declared_services[s]
	msg := sprintf("service %v has a version but is not in the declared service list", [s])
}

# ---------------------------------------------------------------------------
# Every deployment is traceable to a Jira ticket.
# ---------------------------------------------------------------------------

deny[msg] {
	not regex.match("^[A-Z][A-Z0-9]+-[0-9]+$", input.ticket)
	msg := sprintf("%v is not a valid Jira ticket key", [input.ticket])
}
