import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import Component from '@glimmer/component';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { eq } from 'ember-truth-helpers';
import not from 'ember-truth-helpers/helpers/not';

// ── pure helpers ──────────────────────────────────────────────────────────────

function severityMeta(label) {
  const u = (label ?? '').toUpperCase();
  if (u === 'SAFE')         return { cls: 'sev-safe',     text: label };
  if (u.includes('LOW'))    return { cls: 'sev-low',      text: label };
  if (u.includes('MEDIUM')) return { cls: 'sev-medium',   text: label };
  if (u.includes('HIGH'))   return { cls: 'sev-high',     text: label };
  if (u === 'CRITICAL')     return { cls: 'sev-critical', text: label };
  return                           { cls: 'sev-unknown',  text: label ?? '—' };
}

function barW(v) { return `${Math.min(100, Math.max(0, v ?? 0))}%`; }

/** Filter out assumptions with 0 cost since they don't contribute to the score. */
function filterNonZeroCost(items) {
  if (!Array.isArray(items)) return [];
  return items.filter((a) => a.cost > 0);
}

function fmt(n) {
  if (n == null) return '—';
  return Number(n).toLocaleString();
}

/** Show '—' for zero since GitHub stats are often 0 when the API call failed. */
function fmtGithub(n) {
  if (n == null || n === 0) return '—';
  return Number(n).toLocaleString();
}

function phaseLabel(phase) {
  if (phase === 'logs')  return 'Collecting metadata…';
  if (phase === 'trust') return 'Running trust analysis (Z3 solver)…';
  return 'Starting…';
}

/** Returns true only if the logs object has at least one meaningful field. */
function hasLogData(logs) {
  if (!logs || typeof logs !== 'object') return false;
  return (
    logs.downloads != null ||
    (Array.isArray(logs.developers) && logs.developers.length > 0) ||
    (Array.isArray(logs.audits)     && logs.audits.length     > 0) ||
    logs.num_unsafe_calls != null   ||
    logs.num_side_effects != null
  );
}

// Numeric semver comparison — handles "1.2.3" style strings.
function semverCmp(a, b) {
  const pa = (a || '').split('.').map(Number);
  const pb = (b || '').split('.').map(Number);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/** Extract the version an audit covers (version field or delta's "to" version). */
function auditVersion(audit) {
  if (audit.version) return audit.version;
  if (audit.delta) {
    const parts = audit.delta.split('->').map((s) => s.trim());
    if (parts.length === 2) return parts[1];
  }
  return '';
}

/**
 * Returns true when an audit entry should be shown for `version`:
 *   - version audit: show if audit.version ≤ current version
 *   - delta audit: show if delta ends at or before current version (delta.to ≤ version)
 * This shows all audits up to and including the current version.
 */
function isAuditRelevant(audit, version) {
  if (!version) return true;
  if (audit.version) {
    return semverCmp(audit.version, version) <= 0;
  }
  if (audit.delta) {
    const parts = audit.delta.split('->').map((s) => s.trim());
    if (parts.length === 2) {
      const deltaTo = parts[1];
      return semverCmp(deltaTo, version) <= 0;
    }
  }
  return true;
}

// ── component ─────────────────────────────────────────────────────────────────

export default class CrateSherlockReport extends Component {
  @tracked _data     = null;
  @tracked _timer    = null;
  @tracked activeTab = 'logs';

  get data() { return this._data ?? this.args.data; }

  get isRunning() { return this.data?.status === 'running'; }
  get isDone()    { return this.data?.status === 'done'; }
  get fromCache() { return this.data?.cached === true && this.isDone; }

  get hasLogs()  { return hasLogData(this.data?.logs); }
  get hasTrust() { return this.data?.trust != null && !this.data.trust.error; }

  get relevantAudits() {
    const audits = this.data?.logs?.audits;
    if (!Array.isArray(audits)) return [];
    return audits
      .filter((a) => isAuditRelevant(a, this.args.version))
      .sort((a, b) => {
        const vA = auditVersion(a);
        const vB = auditVersion(b);
        return semverCmp(vB, vA);
      });
  }

  constructor(owner, args) {
    super(owner, args);
    if (args.data?.status === 'running') this._startPolling();
  }

  willDestroy() {
    super.willDestroy();
    this._stopPolling();
  }

  @action setTab(tab) { this.activeTab = tab; }

  _startPolling() {
    this._timer = setInterval(async () => {
      try {
        let { crate, version, apiBase } = this.args;
        let resp = await fetch(`${apiBase}/analyze/${crate.id}/${version}`);
        if (!resp.ok) return;
        let fresh = await resp.json();
        this._data = fresh;
        if (fresh.status !== 'running') this._stopPolling();
      } catch { /* network hiccup – keep polling */ }
    }, 3000);
  }

  _stopPolling() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  }

  <template>
    {{! ── offline ── }}
    {{#if @apiError}}
      <div class='offline-card'>
        <span class='offline-icon'>⚠</span>
        <div>
          <p class='offline-title'>cargo-sherlock API server is not running</p>
          <p class='offline-sub'>Start it with:</p>
          <pre class='mono-block'>cd ~/Desktop/cargo-sherlock
source .venv/bin/activate
python3 api_server.py</pre>
          <p class='offline-note'>Listens on <code>127.0.0.1:7070</code></p>
        </div>
      </div>

    {{else if this.isRunning}}
      {{! ── analysis in progress ── }}
      <div class='loading-card'>
        <div class='spinner'></div>
        <div class='loading-body'>
          <p class='loading-title'>
            Running cargo-sherlock on
            <strong>{{@crate.name}} v{{@version}}</strong>
          </p>
          <p class='loading-phase'>{{phaseLabel this.data.phase}}</p>
          <div class='loading-steps'>
            <div class='step {{if (eq this.data.phase "logs") "step-active" "step-done"}}'>
              <span class='step-dot'></span>
              <span>Phase 1 — Collecting metadata (logs mode)</span>
            </div>
            <div class='step {{if (eq this.data.phase "trust") "step-active" ""}}'>
              <span class='step-dot'></span>
              <span>Phase 2 — Computing trust cost (Z3 solver)</span>
            </div>
          </div>
          {{#if this.data.cached}}
            <p class='loading-hint'>Metadata found in cache — trust analysis should be fast.</p>
          {{else}}
            <p class='loading-hint'>First run — collecting metadata then solving. This may take ~60 s.</p>
          {{/if}}
        </div>
      </div>

      {{#if this.hasLogs}}
        <LogsSection
          @logs={{this.data.logs}}
          @crate={{@crate}}
          @version={{@version}}
          @relevantAudits={{this.relevantAudits}}
        />
      {{/if}}

    {{else if this.isDone}}
      {{! ── tab bar ── }}
      <div class='sh-tabs'>
        <ul class='sh-tab-group'>
          <li>
            <button
              type='button'
              class='sh-tab {{if (eq this.activeTab "logs") "sh-tab-active" ""}}'
              {{on "click" (fn this.setTab "logs")}}
            >
              Logs Mode
            </button>
          </li>
          <li>
            <button
              type='button'
              class='sh-tab {{if (eq this.activeTab "trust") "sh-tab-active" ""}}'
              {{on "click" (fn this.setTab "trust")}}
            >
              Trust Mode
            </button>
          </li>
        </ul>
        {{#if this.fromCache}}
          <span class='cache-badge'><span class='cache-icon'>⚡</span>From cache</span>
        {{/if}}
      </div>

      {{! ── logs panel ── }}
      {{#if (eq this.activeTab "logs")}}
        {{#if this.hasLogs}}
          <LogsSection
            @logs={{this.data.logs}}
            @crate={{@crate}}
            @version={{@version}}
            @relevantAudits={{this.relevantAudits}}
          />
        {{else}}
          <p class='empty-state'>Metadata not available for this crate version.</p>
        {{/if}}
      {{/if}}

      {{! ── trust panel ── }}
      {{#if (eq this.activeTab "trust")}}
        {{#if this.hasTrust}}
          <TrustSection @trust={{this.data.trust}} @crate={{@crate}} />
        {{else}}
          <p class='empty-state'>Trust analysis not available for this crate version.</p>
        {{/if}}
      {{/if}}

    {{else}}
      <p class='empty-state'>No results available.</p>
    {{/if}}
  </template>
}

// ── Logs sub-component ────────────────────────────────────────────────────────

class LogsSection extends Component {
  <template>
    <section class='sh-section'>
      <h2 class='sh-section-title'>
        <span class='sh-pill sh-pill-blue'>logs</span>
        Metadata Analysis
        <span class='sh-version-tag'>v{{@version}}</span>
      </h2>

      <div class='meta-grid'>
        <div class='meta-card'>
          <span class='meta-label'>Total Downloads</span>
          <span class='meta-val'>{{fmt @logs.downloads}}</span>
        </div>
        <div class='meta-card'>
          <span class='meta-label'>GitHub Stars</span>
          <span class='meta-val'>{{fmtGithub @logs.stars}}</span>
        </div>
        <div class='meta-card'>
          <span class='meta-label'>GitHub Forks</span>
          <span class='meta-val'>{{fmtGithub @logs.forks}}</span>
        </div>
        <div class='meta-card'>
          <span class='meta-label'>Unsafe Calls</span>
          <span class='meta-val'>{{fmt @logs.num_unsafe_calls}}</span>
        </div>
        <div class='meta-card'>
          <span class='meta-label'>Side Effects</span>
          <span class='meta-val'>{{fmt @logs.num_side_effects}}</span>
        </div>
        <div class='meta-card'>
          <span class='meta-label'>Developers</span>
          <span class='meta-val'>
            {{#if @logs.developers.length}}
              {{#each @logs.developers as |d|}}
                <a class='dev-link' href='https://crates.io/users/{{d}}' target='_blank' rel='noopener'>{{d}}</a>
              {{/each}}
            {{else}}
              —
            {{/if}}
          </span>
        </div>
      </div>

      <div class='flags-row'>
        <Flag @label='RustSec'       @ok={{not @logs.in_rust_sec}}      @passText='Clean'   @failText='Listed' />
        <Flag @label='Unsafe Code'   @ok={{not @logs.num_unsafe_calls}} @passText='None'    @failText='Present' />
        <Flag @label='Side Effects'  @ok={{not @logs.num_side_effects}} @passText='None'    @failText='Present' />
        <Flag @label='Current Audit' @ok={{@logs.passed_audit}}         @passText='Audited' @failText='Not audited' />
      </div>

      {{#if @relevantAudits.length}}
        <div class='audits-wrap'>
          <p class='audits-heading'>
            Audit Records up to v{{@version}}
            ({{@relevantAudits.length}})
          </p>
          <ul class='audits-list'>
            {{#each @relevantAudits as |a|}}
              <li class='audit-row'>
                <span class='audit-org'>{{a.organization}}</span>
                <span class='audit-criteria'>{{a.criteria}}</span>
                {{#if a.version}}
                  <span class='audit-version'>v{{a.version}}</span>
                {{/if}}
                {{#if a.delta}}
                  <span class='audit-delta'>{{a.delta}}</span>
                {{/if}}
                {{#if a.notes}}
                  <span class='audit-notes'>{{a.notes}}</span>
                {{/if}}
              </li>
            {{/each}}
          </ul>
        </div>
      {{else}}
        <p class='empty-state'>No audit records found up to v{{@version}}.</p>
      {{/if}}
    </section>
  </template>
}

// ── Trust sub-component ───────────────────────────────────────────────────────

class TrustSection extends Component {
  <template>
    {{#let (severityMeta @trust.severity) as |sev|}}
      <section class='sh-section'>
        <h2 class='sh-section-title'>
          <span class='sh-pill sh-pill-green'>trust</span>
          Trust Mode Analysis
          {{#if @trust.version}}
            <span class='sh-version-tag'>v{{@trust.version}}</span>
          {{/if}}
        </h2>

        <div class='report-card'>
          <div class='report-header'>
            <span class='report-title'>Analysis Report</span>
            <span class='report-crate'>
              {{@crate.name}}
              {{#if @trust.version}}
                <span class='report-version'>v{{@trust.version}}</span>
              {{/if}}
            </span>
          </div>

          <div class='report-row'>
            <span class='row-key'>Cost Range</span>
            <span class='row-val muted'>0 (Min) — 100 (Max)</span>
          </div>

          <div class='report-row'>
            <span class='row-key'>Trust Cost <span class='row-hint'>(lower is better)</span></span>
            <div class='bar-wrap'><div class='bar trust-bar' style='width: {{barW @trust.trust_cost}}'></div></div>
            <span class='row-num trust-num'>{{@trust.trust_cost}}</span>
          </div>

          <div class='report-row'>
            <span class='row-key'>Distrust Cost <span class='row-hint'>(higher is better)</span></span>
            <div class='bar-wrap'><div class='bar distrust-bar' style='width: {{barW @trust.distrust_cost}}'></div></div>
            <span class='row-num distrust-num'>{{@trust.distrust_cost}}</span>
          </div>

          <div class='report-row severity-row'>
            <span class='row-key'>Severity Label</span>
            <span class='severity-pill {{sev.cls}}'>{{sev.text}}</span>
          </div>
        </div>

        {{#let (filterNonZeroCost @trust.trusting) as |nonZeroTrusting|}}
          {{#if nonZeroTrusting.length}}
            <div class='assumptions-block trust-block'>
              <div class='block-title trust-title'>Assumptions for Trusting</div>
              <ul class='assumption-list'>
                {{#each nonZeroTrusting as |a|}}
                  <li class='assumption-item'>
                    <span class='item-dot trust-dot'>•</span>
                    <span class='item-text'>{{a.label}}</span>
                    <span class='item-badge trust-badge'>{{a.cost}} cost</span>
                  </li>
                {{/each}}
              </ul>
            </div>
          {{/if}}
        {{/let}}

        {{#let (filterNonZeroCost @trust.distrusting) as |nonZeroDistrusting|}}
          {{#if nonZeroDistrusting.length}}
            <div class='assumptions-block distrust-block'>
              <div class='block-title distrust-title'>Assumptions for Distrusting</div>
              <ul class='assumption-list'>
                {{#each nonZeroDistrusting as |a|}}
                  <li class='assumption-item'>
                    <span class='item-dot distrust-dot'>•</span>
                    <span class='item-text'>{{a.label}}</span>
                    <span class='item-badge distrust-badge'>{{a.cost}} cost</span>
                  </li>
                {{/each}}
              </ul>
            </div>
          {{/if}}
        {{/let}}

        <details class='raw-details'>
          <summary class='raw-summary'>Raw cargo-sherlock output</summary>
          <pre class='raw-pre'>{{@trust.raw_output}}</pre>
        </details>
      </section>
    {{/let}}
  </template>
}

// ── Flag badge helper ─────────────────────────────────────────────────────────

class Flag extends Component {
  <template>
    <div class='flag {{if @ok "flag-ok" "flag-fail"}}'>
      <span class='flag-icon'>{{if @ok "✓" "✗"}}</span>
      <span class='flag-label'>{{@label}}</span>
      <span class='flag-val'>{{if @ok @passText @failText}}</span>
    </div>
  </template>
}
