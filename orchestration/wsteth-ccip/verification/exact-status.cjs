'use strict';

// Source availability alone includes Similar Match. Never use it as an Exact Match gate.
function hex(value) {
  if (typeof value !== 'string' || !/^(?:0x)?(?:[0-9a-f]{2})*$/i.test(value)) throw Error('Invalid constructor argument encoding');
  return value.replace(/^0x/i, '').toLowerCase();
}

function classify(source, expectedConstructorArguments) {
  const sourceAvailable = typeof source.SourceCode === 'string' && source.SourceCode.trim().length > 0;
  const similarMatch = String(source.SimilarMatch || '').trim() || null;
  const actual = hex(source.ConstructorArguments || '');
  const expected = expectedConstructorArguments === undefined ? undefined : hex(expectedConstructorArguments);
  const constructorArgumentsMatch = expected === undefined ? null : actual === expected;
  // Unknown constructor inputs are explicitly unaudited. Empty expected inputs are valid.
  const exactVerified = sourceAvailable && !similarMatch && constructorArgumentsMatch === true;
  return {sourceAvailable, similarMatch, matchType: !sourceAvailable ? 'unverified' : similarMatch ? 'similar' : 'no-similar-marker',
    expectedConstructorBytes: expected === undefined ? null : expected.length / 2,
    publishedConstructorBytes: actual.length / 2, constructorArgumentsMatch, exactVerified,
    result: exactVerified ? 'exact-verified' : !sourceAvailable ? 'unverified' : similarMatch ? 'similar-match' :
      expected === undefined ? 'constructor-not-audited' : 'constructor-mismatch'};
}

function requireExact(source, expectedConstructorArguments) {
  const status = classify(source, expectedConstructorArguments);
  if (!status.exactVerified) throw Error('Exact verification incomplete: ' + status.result);
  return status;
}

module.exports = {classify, requireExact};
