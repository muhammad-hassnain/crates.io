import CrateHeader from 'crates-io/components/crate-header';
import CrateSherlockReport from 'crates-io/components/crate-sherlock-report';

<template>
  <CrateHeader
    @crate={{@controller.crate}}
    @versionNum={{@controller.version}}
  />
  <CrateSherlockReport
    @crate={{@controller.crate}}
    @version={{@controller.version}}
    @data={{@controller.data}}
    @apiBase={{@controller.apiBase}}
    @apiError={{@controller.apiError}}
  />
</template>
