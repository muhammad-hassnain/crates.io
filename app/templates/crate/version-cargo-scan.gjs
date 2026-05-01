import CrateHeader from 'crates-io/components/crate-header';
import CrateCargoScanReport from 'crates-io/components/crate-cargo-scan-report';

<template>
  <CrateHeader
    @crate={{@controller.crate}}
    @versionNum={{@controller.version}}
  />
  <CrateCargoScanReport
    @crate={{@controller.crate}}
    @version={{@controller.version}}
    @data={{@controller.data}}
    @apiBase={{@controller.apiBase}}
    @apiError={{@controller.apiError}}
  />
</template>
