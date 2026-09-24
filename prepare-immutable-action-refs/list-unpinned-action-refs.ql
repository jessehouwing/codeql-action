/**
 * @name List candidate action refs for immutable-release verification
 * @description Lists distinct `(owner/repo, ref)` pairs used by `uses:` steps and reusable
 *              workflow calls that are not already pinned to a commit SHA, and are therefore
 *              candidates for checking against GitHub's Immutable Releases feature.
 *
 *              Keep this file in sync with
 *              `actions/ql/src/utils/ListUnpinnedActionRefs.ql` in the `github/codeql` repository,
 *              which is the source of truth for this query. It is duplicated here so that this
 *              action can run it standalone, without depending on the `github/codeql` source
 *              repository being checked out.
 * @kind table
 * @id actions/list-unpinned-action-refs
 * @tags utility
 *       actions
 */

import actions

bindingset[version]
private predicate isPinnedCommit(string version) {
  version.regexpMatch("^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?$")
}

bindingset[nwo]
private predicate isContainerImage(string nwo) { nwo.regexpMatch("^docker://.+") }

// A `$/` reference is a same-repository (self repository) reference, resolved at the commit
// the calling workflow is running. Like `./` local references, it is inherently pinned.
bindingset[nwo]
private predicate isSelfRepository(string nwo) { nwo.matches("$/%") }

bindingset[nwo]
private string normalizeToRepo(string nwo) { result = nwo.regexpCapture("^([^/]+/[^/]+)(?:/.*)?$", 1) }

from Uses uses, string nwo, string version
where
  uses.getCallee() = nwo and
  uses.getVersion() = version and
  not isSelfRepository(nwo) and
  not isContainerImage(nwo) and
  not isPinnedCommit(version)
select normalizeToRepo(nwo) as action, version as ref
