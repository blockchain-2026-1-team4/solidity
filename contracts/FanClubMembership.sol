// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract FanClubMembership is ERC721, AccessControl {
    bytes32 public constant MEMBERSHIP_ISSUER_ROLE = keccak256("MEMBERSHIP_ISSUER_ROLE");

    uint256 private _nextTokenId = 1;
    mapping(address => uint256) private _membershipOf;

    error InvalidAddress();
    error AlreadyMember();
    error NotMember();
    error MembershipTransferRestricted();

    event MembershipIssued(address indexed member, uint256 indexed tokenId);
    event MembershipRevoked(address indexed member, uint256 indexed tokenId);

    constructor(address admin) ERC721("FANCLUB-MEMBERSHIP", "FAN") {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MEMBERSHIP_ISSUER_ROLE, admin);
    }

    function issueMembership(address member) external onlyRole(MEMBERSHIP_ISSUER_ROLE) returns (uint256 tokenId) {
        if (member == address(0)) revert InvalidAddress();
        if (_membershipOf[member] != 0) revert AlreadyMember();

        tokenId = _nextTokenId++;
        _membershipOf[member] = tokenId;
        _safeMint(member, tokenId);

        emit MembershipIssued(member, tokenId);
    }

    function revokeMembership(address member) external onlyRole(MEMBERSHIP_ISSUER_ROLE) {
        if (member == address(0)) revert InvalidAddress();
        uint256 tokenId = _membershipOf[member];
        if (tokenId == 0) revert NotMember();

        delete _membershipOf[member];
        _burn(tokenId);

        emit MembershipRevoked(member, tokenId);
    }

    function membershipOf(address member) external view returns (uint256) {
        if (member == address(0)) revert InvalidAddress();
        return _membershipOf[member];
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert MembershipTransferRestricted();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
