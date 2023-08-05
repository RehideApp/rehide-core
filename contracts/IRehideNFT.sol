// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IRehideNFT {

    struct Note {
        address creator;
        string package;
        uint256 readsAvailable;
        uint256 readPrice;
        uint256 ttl;
        uint256 allowlistOnly;
    }

    struct NoteRead {
        address reader;
        uint256 timestamp;
    }

    // struct Tier {
    //     uint256 rebate;
    //     uint256 discount;
    // }

    function pause() external;
    function unpause() external;
    function setBaseURI(string memory uri) external;
    function withdraw() external returns (uint256);
    function updateTokenURI(uint256 _tokenId, string memory _newUri) external;
    function burn(uint256 tokenId) external;
    
    event Pause(uint256 timestamp);
    event Unpause(uint256 timestamp);
    event TogglePauseErc20(bool isErc20Paused, uint256 timestamp);
    event SetBaseURI(string baseURI);
    event Withdraw(uint256 balance);
    event SetTokenPackage(uint256 indexed tokenId, string tokenPackage);
    event UpdateTokenUri(uint256 indexed tokenId, string uri);
    event Burn(uint256 indexed tokenId);
    event SetExpireNote(uint256 indexed tokenId);
    event TokenCreated(uint256 indexed tokenId, string tokenURI, address indexed tokenOwner);
    event MintNFT(uint256 indexed newTokenId, string uri, address indexed recipient, uint256 ethMintPrice);
    event ReadSharedNote(uint256 indexed tokenId, address indexed reader, uint256 timestamp);
    event ReadSharedNoteRewardsTransferred(address indexed creator, uint256 indexed tokenId, uint256 reward);
    event SetReferrer(address indexed referee, address indexed referrer);
    event RewardsTransferred(address indexed referrer, uint256 reward);
    event AddToReadAllowlist(uint256 indexed tokenId, address[] toAddAddresses);
    event AddToReadDenylist(uint256 indexed tokenId, address[] toAddAddresses);
    // event SelfAddToReadDenylist(uint256 indexed tokenId, address account);
    event AddAddressesToBlacklist(address reporter, address[] toAddAddresses);
    event AddAddressesToPlatformBlacklist(address[] toAddAddresses);
    event UpdateAllowListOnly(uint256 indexed tokenId, uint256 allowListOnly);
    event UpdateReferrerTierList(address[] toAddAddresses, uint256 tierId);
    event RemoveFromReferrerTierList(address[] toRemoveAddresses, uint256 tierId);
    event SetTier(uint256 indexed tierId, uint256 rebate);
    event MintPassWithERC20(uint256 indexed newTokenId, uint256 erc20MintPrice, address indexed erc20MintAddress);
}
