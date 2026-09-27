const fs = require('node:fs');
const ts = require('typescript');
const inventory = require('./fixtures/api-contract.json');
const normalize = text => text.replace(/\s/g, '').replace(/'/g, '"').replace(/;(?=})/g, '').replace(/,(?=\))/g, '');

test('all original audited fields remain compatible alongside the new public features', () => {
  const source = ts.createSourceFile('types.ts', fs.readFileSync(require.resolve('../src/types/index.ts'), 'utf8'), ts.ScriptTarget.Latest, true);
  const actual = new Map();
  const names = [];
  function fields(owner, members) {
    for (const member of members) {
      if (ts.isPropertySignature(member)) {
        const name = `${owner}.${member.name.getText(source)}`;
        actual.set(normalize(name), { type: normalize(member.type.getText(source)), required: !member.questionToken });
        if (ts.isTypeLiteralNode(member.type)) fields(name, member.type.members);
      } else if (ts.isIndexSignatureDeclaration(member)) {
        const parameter = member.parameters[0];
        actual.set(normalize(`${owner}.[${parameter.name.getText(source)}: ${parameter.type.getText(source)}]`), { type: normalize(member.type.getText(source)), required: 'index signature' });
      }
    }
  }
  for (const statement of source.statements) {
    if (ts.isInterfaceDeclaration(statement)) { names.push(statement.name.text); fields(statement.name.text, statement.members); }
    else if (ts.isTypeAliasDeclaration(statement)) names.push(statement.name.text);
  }
  const expectedNames = inventory.types;
  expect(names).toEqual(expect.arrayContaining(expectedNames));
  const expected = inventory.fields;
  expect(actual.size).toBeGreaterThanOrEqual(expected.length);
  for (const field of expected) {
    const required = field.required === 'required when resolution is present' ? true : field.required;
    expect({ name: field.name, ...actual.get(normalize(field.name)) }).toEqual({ name: field.name, type: normalize(field.declaredType), required });
  }
});
