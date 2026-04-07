// Intentionally empty stub. Railcart runs on Node, not React Native, so
// @graphql-mesh/cross-helpers never actually executes the react-native-fs
// branch — but npm still installs it as a hard dep, dragging in ~150MB of
// react-native + metro + babel. This stub satisfies resolution at zero cost.
module.exports = {};
