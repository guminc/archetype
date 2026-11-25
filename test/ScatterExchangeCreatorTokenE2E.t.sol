// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ScatterExchange} from "../src/ScatterExchange.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ICreatorTokenTransferValidator {
    function createList(string calldata name) external returns (uint120 id);
    function addAccountsToWhitelist(uint120 id, address[] calldata accounts) external;
    function applyListToCollection(address collection, uint120 id) external;
    function setTransferSecurityLevelOfCollection(
        address collection,
        uint8 level,
        bool disableAuthorizationMode,
        bool disableWildcardOperators,
        bool enableAccountFreezingMode
    ) external;
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
    function validateTransfer(address caller, address from, address to, uint256 tokenId, uint256 amount) external;
}

/// Runs the exchange against the runtime bytecode of Limit Break's deployed
/// CreatorTokenTransferValidator, the contract that ERC721-C and ERC1155-C
/// collections ask before every transfer.
contract ScatterExchangeCreatorTokenE2ETest is Test {
    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));
    uint256 internal constant BIDDER_PK = uint256(keccak256("bidder"));

    bytes4 internal constant CALLER_MUST_BE_WHITELISTED =
        bytes4(keccak256("CreatorTokenTransferValidator__CallerMustBeWhitelisted()"));

    ScatterExchange internal subject;

    ICreatorTokenTransferValidator internal validator;
    CreatorTokenErc721 internal nft721;
    CreatorTokenErc1155 internal nft1155;
    CreatorTokenTestErc20 internal weth;

    address internal creator = makeAddr("creator");
    address internal seller = vm.addr(SELLER_PK);
    address internal bidder = vm.addr(BIDDER_PK);
    address internal buyer = makeAddr("buyer");
    address internal otherMarketplace = makeAddr("otherMarketplace");

    function setUp() public {
        string memory artifact = vm.readFile("test/fixtures/creator-token-transfer-validator.json");
        validator = ICreatorTokenTransferValidator(vm.parseJsonAddress(artifact, ".address"));
        vm.etch(address(validator), vm.parseJsonBytes(artifact, ".runtime"));

        ScatterCollectionRegistry registry = new ScatterCollectionRegistry(address(this));
        subject = new ScatterExchange(makeAddr("owner"), registry, makeAddr("feeAuthorizer"));

        _prank(creator);
        nft721 = new CreatorTokenErc721(validator);
        nft1155 = new CreatorTokenErc1155(validator);
        weth = new CreatorTokenTestErc20();

        nft721.mint(seller, 1);
        nft1155.mint(seller, 1, 10);
        weth.mint(bidder, 100 ether);
        vm.deal(buyer, 100 ether);

        _prank(seller);
        nft721.setApprovalForAll(address(subject), true);
        nft721.setApprovalForAll(otherMarketplace, true);
        nft1155.setApprovalForAll(address(subject), true);
        _prank(bidder);
        weth.approve(address(subject), type(uint256).max);
    }

    /// Levels 0 and 3 allow owner-initiated transfers, 4 forbids them, and 5 and
    /// 7 add the rule that receivers hold no code.
    function test_e2e_listing_settlesOnlyAfterTheCollectionWhitelistsTheExchange() public {
        uint8[5] memory levels = [0, 3, 4, 5, 7];
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_submission(ScatterExchange.Role.Listing, _item721(1, address(0))), SELLER_PK, 1, 1));

        for (uint256 i = 0; i < levels.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _prank(creator);
            validator.setTransferSecurityLevelOfCollection(address(nft721), levels[i], false, false, false);

            _prank(buyer);
            vm.expectRevert(CALLER_MUST_BE_WHITELISTED);
            subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

            _whitelistExchange(address(nft721));
            _prank(buyer);
            subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

            assertEq(nft721.ownerOf(1), buyer);
            vm.revertToState(snapshot);
        }
    }

    function test_e2e_listing_whitelistingTheExchangeDoesNotAdmitAnotherOperator() public {
        _whitelistExchange(address(nft721));

        _prank(otherMarketplace);
        vm.expectRevert(CALLER_MUST_BE_WHITELISTED);
        nft721.transferFrom(seller, buyer, 1);
    }

    function test_e2e_bid_sellerSellsIntoBidOnAWhitelistOnlyCollection() public {
        _whitelistExchange(address(nft721));
        _prank(creator);
        validator.setTransferSecurityLevelOfCollection(address(nft721), 4, false, false, false);
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_submission(ScatterExchange.Role.Bid, _item721(0, address(weth))), BIDDER_PK, 1, 1));

        _prank(seller);
        subject.sellIntoBids(inputs, 500, address(0), 0, "");

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(weth.balanceOf(seller), 0.95 ether);
    }

    function test_e2e_listing_settlesErc1155CreatorToken() public {
        ScatterExchange.ScatterListing memory item = ScatterExchange.ScatterListing({
            assetType: ScatterExchange.AssetType.ERC1155,
            collection: address(nft1155),
            tokenId: 1,
            quantity: 10,
            currency: address(0),
            priceWei: 0.1 ether
        });
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_submission(ScatterExchange.Role.Listing, item), SELLER_PK, 1, 4));

        _prank(buyer);
        vm.expectRevert(CALLER_MUST_BE_WHITELISTED);
        subject.buyListings{value: 0.4 ether}(inputs, buyer, address(0), 0, "");

        _whitelistExchange(address(nft1155));
        _prank(buyer);
        subject.buyListings{value: 0.4 ether}(inputs, buyer, address(0), 0, "");

        assertEq(nft1155.balanceOf(buyer, 1), 4);
        assertEq(nft1155.balanceOf(seller, 1), 6);
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }

    function _whitelistExchange(address collection) internal {
        _prank(creator);
        uint120 listId = validator.createList("scatter only");
        address[] memory accounts = new address[](1);
        accounts[0] = address(subject);
        validator.addAccountsToWhitelist(listId, accounts);
        validator.applyListToCollection(collection, listId);
    }

    function _item721(uint256 tokenId, address currency) internal view returns (ScatterExchange.ScatterListing memory) {
        return ScatterExchange.ScatterListing({
            assetType: ScatterExchange.AssetType.ERC721,
            collection: address(nft721),
            tokenId: tokenId,
            quantity: 1,
            currency: currency,
            priceWei: 1 ether
        });
    }

    function _submission(ScatterExchange.Role role, ScatterExchange.ScatterListing memory item)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory submission)
    {
        submission.role = role;
        submission.listings = new ScatterExchange.ScatterListing[](1);
        submission.listings[0] = item;
        submission.maxFeeBps = 500;
        submission.startTime = block.timestamp;
        submission.endTime = block.timestamp + 1 hours;
    }

    function _input(
        ScatterExchange.ScatterSubmission memory submission,
        uint256 signerPk,
        uint256 fillTokenId,
        uint256 fillQuantity
    ) internal view returns (ScatterExchange.FillInput memory input) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, subject.hashSubmission(submission));
        input.submission = submission;
        input.submissionSig = abi.encodePacked(r, s, v);
        input.fills = new ScatterExchange.ScatterFill[](1);
        input.fills[0] = ScatterExchange.ScatterFill({itemIndex: 0, tokenId: fillTokenId, quantity: fillQuantity});
    }

    function _single(ScatterExchange.FillInput memory input)
        internal
        pure
        returns (ScatterExchange.FillInput[] memory inputs)
    {
        inputs = new ScatterExchange.FillInput[](1);
        inputs[0] = input;
    }
}

/// Asks the validator before each transfer, as Limit Break's ERC721C does.
contract CreatorTokenErc721 is ERC721, Ownable {
    ICreatorTokenTransferValidator internal immutable VALIDATOR;

    constructor(ICreatorTokenTransferValidator validator) ERC721("Creator Token 721", "CT721") Ownable(msg.sender) {
        VALIDATOR = validator;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function getTransferValidator() external view returns (address) {
        return address(VALIDATOR);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) VALIDATOR.validateTransfer(msg.sender, from, to, tokenId);
    }
}

/// Asks the validator before each transfer, as Limit Break's ERC1155C does.
contract CreatorTokenErc1155 is ERC1155, Ownable {
    ICreatorTokenTransferValidator internal immutable VALIDATOR;

    constructor(ICreatorTokenTransferValidator validator) ERC1155("") Ownable(msg.sender) {
        VALIDATOR = validator;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function getTransferValidator() external view returns (address) {
        return address(VALIDATOR);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                VALIDATOR.validateTransfer(msg.sender, from, to, ids[i], values[i]);
            }
        }
        super._update(from, to, ids, values);
    }
}

contract CreatorTokenTestErc20 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
