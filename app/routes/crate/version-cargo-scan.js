import Route from '@ember/routing/route';

const API_BASE = 'http://127.0.0.1:7070';

export default class VersionCargoScanRoute extends Route {
  async model(params) {
    let crate = this.modelFor('crate');
    let version = params.version_num;

    try {
      let resp = await fetch(`${API_BASE}/scan/${crate.id}/${version}`);
      if (!resp.ok) throw new Error(`API ${resp.status}`);
      let data = await resp.json();
      return { crate, version, data, apiBase: API_BASE, apiError: null };
    } catch (err) {
      return { crate, version, data: null, apiBase: API_BASE, apiError: err.message };
    }
  }

  setupController(controller, { crate, version, data, apiBase, apiError }) {
    super.setupController(...arguments);
    controller.crate    = crate;
    controller.version  = version;
    controller.data     = data;
    controller.apiBase  = apiBase;
    controller.apiError = apiError;
  }
}
