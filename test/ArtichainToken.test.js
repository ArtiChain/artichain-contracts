const { assert } = require("chai");

const ArtichainToken = artifacts.require('ArtichainToken');

contract('ArtichainToken', ([alice, bob, carol, dev, minter]) => {
    beforeEach(async () => {
        this.ait = await ArtichainToken.new({ from: minter });
    });


    it('mint', async () => {
        await this.ait.mint(alice, 1000, { from: minter });
        assert.equal((await this.ait.balanceOf(alice)).toString(), '1000');
    })
});
