// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "./IRehideBase.sol";

abstract contract RehideBase is ERC721Enumerable, ERC721URIStorage, Pausable, Ownable, IRehideBase {
        /**
     * @dev NFT
     */
    using Counters for Counters.Counter;

    /**
     * @dev Payment
     */
    address payable public _platformWallet = payable(0x418DeE19Bc3659bd6eFc5f990461320cDfedd91E);
    uint256 public _minEthMintPrice = 0; //1000000000000000; // wei = 0.001 ETH
    uint256 public _readPlatformPercentage = 5;

    /**
     * @dev Referrer Rewards
     */
    mapping(address => address) public _referrers; // referee => referrer
    Counters.Counter public _referrerIds; // no. of referrers
    uint256 public _primaryReferrerPercentage = 5; // % to pay primary referrer
    uint256 public _secondaryReferrerPercentage = 2; // % to pay each secondary referrer
    uint256 public _maxReferrerLevels = 5; // max no. of secondary referrers to pay per tx
    uint256 public _maxReferrerRewardsPercentage = 60; // safety limit, max rewards paid per tx
    mapping(address => uint256) public _referrerRewards; // total rewards received per address
    uint256 public _totalReferrerMintRewards; // total mint rewards received by all referrers
    uint256 public _totalPlatformMintFees; // total mint fees received by platform

    mapping(address => uint256) public _referrerTierList; // tier Id for address
    Counters.Counter public _referrerTierCount;

    mapping(address => uint256) public _creatorReadFees; // total read fees received per address
    uint256 public _totalCreatorsReadFees; // total read fees received by all creators
    uint256 public _totalPlatformReadFees; // total read fees received by platform

    // Counters.Counter public _discountAddressIds;
    // mapping(address => uint256) public _discountAddressList; // discount % for address

    function setPlatformWallet(address payable platformWallet) external onlyOwner {
        require(platformWallet != address(0), "RehideNFT: Address cannot be the zero address");
        _platformWallet = platformWallet;
        emit SetPlatformWallet(_platformWallet);
    }

    function setMinEthMintPrice(uint256 minEthMintPrice) external onlyOwner {
        _minEthMintPrice = minEthMintPrice;
        emit SetMinEthMintPrice(_minEthMintPrice);
    }
    
    function setPrimaryReferrerPercentage(uint256 primaryReferrerPercentage) external onlyOwner {
        _primaryReferrerPercentage = primaryReferrerPercentage;
        emit SetPrimaryReferrerPercentage(_primaryReferrerPercentage);
    }

    function setSecondaryReferrerPercentage(uint256 secondaryReferrerPercentage) external onlyOwner {
        _secondaryReferrerPercentage = secondaryReferrerPercentage;
        emit SetSecondaryReferrerPercentage(_secondaryReferrerPercentage);
    }    

    function setMaxReferrerLevels(uint256 maxReferrerLevels) external onlyOwner {
        _maxReferrerLevels = maxReferrerLevels;
        emit SetMaxReferrerLevels(_maxReferrerLevels);
    }    

    function setMaxReferrerRewardsPercentage(uint256 maxReferrerRewardsPercentage) external onlyOwner {
        _maxReferrerRewardsPercentage = maxReferrerRewardsPercentage;
        emit SetMaxReferrerRewardsPercentage(_maxReferrerRewardsPercentage);
    }

    function setReadPlatformPercentage(uint256 readPlatformPercentage) external onlyOwner {
        _readPlatformPercentage = readPlatformPercentage;
        emit SetReadPlatformPercentage(_readPlatformPercentage);
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal whenNotPaused override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
