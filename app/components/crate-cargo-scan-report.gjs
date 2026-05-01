import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import Component from '@glimmer/component';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { eq } from 'ember-truth-helpers';

// Effect type metadata
const EFFECT_META = {
  UnsafeCall:      { color: 'effect-unsafe',  icon: '⚠', label: 'Unsafe Call' },
  FnPtrCreation:   { color: 'effect-fnptr',   icon: '→', label: 'Fn Pointer' },
  ClosureCreation: { color: 'effect-closure', icon: 'λ', label: 'Closure' },
  PtrDeref:        { color: 'effect-ptr',     icon: '*', label: 'Ptr Deref' },
  FFICall:         { color: 'effect-ffi',     icon: 'C', label: 'FFI Call' },
  default:         { color: 'effect-other',   icon: '•', label: 'Other' },
};

function getEffectMeta(type) {
  return EFFECT_META[type] || { ...EFFECT_META.default, label: type };
}

function phaseLabel(phase) {
  if (phase === 'downloading') return 'Downloading crate…';
  if (phase === 'scanning')    return 'Running cargo-scan…';
  return 'Queued…';
}

export default class CrateCargoScanReport extends Component {
  @tracked _data      = null;
  @tracked _timer     = null;
  @tracked activeType = null;

  get data() { return this._data ?? this.args.data; }

  get isRunning() { return this.data?.status === 'running'; }
  get isDone()    { return this.data?.status === 'done'; }
  get isError()   { return this.data?.status === 'error'; }
  get fromCache() { return this.data?.cached === true && this.isDone; }

  get effects() { return this.data?.data?.effects ?? []; }
  get byType()  { return this.data?.data?.by_type ?? {}; }
  get summary() { return this.data?.data?.summary ?? {}; }

  get effectTypes() {
    const types = Object.keys(this.byType).sort((a, b) => {
      return (this.byType[b]?.length ?? 0) - (this.byType[a]?.length ?? 0);
    });
    return types.map((t) => ({
      type: t,
      count: this.byType[t]?.length ?? 0,
      meta: getEffectMeta(t),
    }));
  }

  get filteredEffects() {
    if (!this.activeType) return this.effects;
    return this.byType[this.activeType] ?? [];
  }

  get csvContent() {
    const header = 'crate,function,callee,effect,file,line,col';
    const rows = this.effects.map((e) =>
      `"${e.crate}","${e.fn_decl}","${e.callee}","${e.effect}","${e.file}",${e.line},${e.col}`
    );
    return [header, ...rows].join('\n');
  }

  constructor(owner, args) {
    super(owner, args);
    if (args.data?.status === 'running') this._startPolling();
  }

  willDestroy() {
    super.willDestroy();
    this._stopPolling();
  }

  @action setFilter(type) {
    this.activeType = this.activeType === type ? null : type;
  }

  @action downloadCsv() {
    const blob = new Blob([this.csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${this.args.crate.name}-${this.args.version}-effects.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  _startPolling() {
    this._timer = setInterval(async () => {
      try {
        let { crate, version, apiBase } = this.args;
        let resp = await fetch(`${apiBase}/scan/${crate.id}/${version}`);
        if (!resp.ok) return;
        let fresh = await resp.json();
        this._data = fresh;
        if (fresh.status !== 'running') this._stopPolling();
      } catch { /* keep polling */ }
    }, 2000);
  }

  _stopPolling() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  }

  <template>
    {{#if @apiError}}
      <div class='scan-offline'>
        <span class='offline-icon'>⚠</span>
        <div>
          <p class='offline-title'>cargo-scan API not running</p>
          <pre class='mono-cmd'>cd ~/Desktop/cargo-sherlock && source .venv/bin/activate && python3 api_server.py</pre>
        </div>
      </div>

    {{else if this.isError}}
      <div class='scan-offline'>
        <span class='offline-icon'>✗</span>
        <p class='offline-title'>Scan failed: {{this.data.error}}</p>
      </div>

    {{else if this.isRunning}}
      <div class='scan-loading'>
        <div class='spinner'></div>
        <div>
          <p class='loading-title'>Running cargo-scan on <strong>{{@crate.name}} v{{@version}}</strong></p>
          <p class='loading-phase'>{{phaseLabel this.data.phase}}</p>
        </div>
      </div>

    {{else if this.isDone}}
      <div class='scan-frame'>
        <section class='scan-report'>
          <header class='scan-header'>
            <div class='scan-title-row'>
              <h2 class='scan-title'>Side Effects Analysis <span class='scan-ver'>v{{@version}}</span></h2>
              {{#if this.fromCache}}
                <span class='cache-pill'>⚡ From Cache</span>
              {{/if}}
            </div>
            <div class='scan-actions'>
              <button type='button' class='btn-download' {{on "click" this.downloadCsv}}>
                ↓ Download CSV
              </button>
            </div>
          </header>

          {{! Summary row }}
          <div class='scan-stats'>
            <div class='stat-box stat-primary'>
              <span class='stat-num'>{{this.summary.total_effects}}</span>
              <span class='stat-label'>Total Effects</span>
            </div>
            <div class='stat-box'>
              <span class='stat-num'>{{this.effectTypes.length}}</span>
              <span class='stat-label'>Effect Types</span>
            </div>
          </div>

          {{! Filter chips }}
          <div class='filter-bar'>
            <button
              type='button'
              class='filter-chip {{unless this.activeType "active"}}'
              {{on "click" (fn this.setFilter null)}}
            >All ({{this.summary.total_effects}})</button>
            {{#each this.effectTypes as |et|}}
              <button
                type='button'
                class='filter-chip {{et.meta.color}} {{if (eq this.activeType et.type) "active"}}'
                {{on "click" (fn this.setFilter et.type)}}
              >
                <span class='chip-icon'>{{et.meta.icon}}</span>
                {{et.meta.label}} ({{et.count}})
              </button>
            {{/each}}
          </div>

          {{! Effects table }}
          <div class='table-wrap'>
            <table class='effects-table'>
              <thead>
                <tr>
                  <th class='th-type'>Type</th>
                  <th class='th-file'>File</th>
                  <th class='th-line'>Line</th>
                  <th class='th-fn'>Function</th>
                  <th class='th-callee'>Callee</th>
                </tr>
              </thead>
              <tbody>
                {{#each this.filteredEffects as |eff|}}
                  {{#let (getEffectMeta eff.effect) as |meta|}}
                    <tr>
                      <td class='td-type'>
                        <span class='type-badge {{meta.color}}'>
                          <span class='badge-icon'>{{meta.icon}}</span>
                          {{meta.label}}
                        </span>
                      </td>
                      <td class='td-file'><code>{{eff.file}}</code></td>
                      <td class='td-line'>{{eff.line}}</td>
                      <td class='td-fn'><code>{{eff.fn_decl}}</code></td>
                      <td class='td-callee'><code>{{eff.callee}}</code></td>
                    </tr>
                  {{/let}}
                {{/each}}
              </tbody>
            </table>
          </div>

          {{#unless this.filteredEffects.length}}
            <p class='no-effects'>No side effects found.</p>
          {{/unless}}
        </section>
      </div>
    {{else}}
      <p class='no-effects'>No scan results available.</p>
    {{/if}}
  </template>
}
