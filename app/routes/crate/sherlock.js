import Route from '@ember/routing/route';

const API_BASE = 'http://127.0.0.1:7070';

export default class SherlockRoute extends Route {
  async model() {
    let crate = this.modelFor('crate');
    let version = crate.default_version ?? crate.max_stable_version ?? crate.newest_version ?? null;

    try {
      let url = version
        ? `${API_BASE}/analyze/${crate.id}/${version}`
        : `${API_BASE}/analyze/${crate.id}`;
      let resp = await fetch(url);
      if (!resp.ok) throw new Error(`API ${resp.status}`);
      let data = await resp.json();
      return { crate, version, data, apiBase: API_BASE, apiError: null };
    } catch (err) {
      return { crate, version, data: null, apiBase: API_BASE, apiError: err.message };
    }
  }

  setupController(controller, { crate, version, data, apiBase, apiError }) {
    super.setupController(...arguments);
    controller.crate   = crate;
    controller.version = version;
    controller.data    = data;
    controller.apiBase = apiBase;
    controller.apiError = apiError;
  }
}
