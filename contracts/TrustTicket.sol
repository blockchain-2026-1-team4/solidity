// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TrustTicket is ERC721Enumerable, AccessControl, ReentrancyGuard {
    bytes32 public constant ORGANIZER_ROLE = keccak256("ORGANIZER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    uint256 public constant RESALE_RATE_DENOMINATOR = 10_000;

    struct EventInfo {
        uint256 eventId;
        address organizer;
        string eventName;
        uint256 eventTimestamp;
        uint256 ticketPrice;
        uint256 totalTicketCount;
        uint256 remainingTicketCount;
        uint256 primarySaleStart;
        uint256 primarySaleEnd;
        bool resaleAllowed;
        uint256 maxResalePriceRate;
        uint256 resaleStart;
        uint256 resaleEnd;
        bool active;
    }

    struct TicketInfo {
        uint256 tokenId;
        uint256 eventId;
        string seatInfo;
        uint256 originalPrice;
        bool used;
        bool listed;
    }

    struct ListingInfo {
        uint256 tokenId;
        address seller;
        uint256 price;
        bool active;
    }

    error NotOrganizer();
    error NotEventOrganizer();
    error NotValidator();
    error InvalidAddress();
    error InvalidEvent();
    error InvalidSaleWindow();
    error InvalidTicketSupply();
    error InvalidPrice();
    error EventInactive();
    error PrimarySaleClosed();
    error ResaleClosed();
    error ResaleNotAllowed();
    error TicketUnavailable();
    error TicketUsedError();
    error TicketListedError();
    error TicketNotListed();
    error NotTicketOwner();
    error SelfPurchase();
    error PriceCapExceeded();
    error PaymentTransferFailed();
    error PurchaseNotEligible();

    uint256 private _nextEventId = 1;
    uint256 private _nextTokenId = 1;
    bool private _marketplaceTransfer;

    mapping(uint256 => EventInfo) private _events;
    mapping(uint256 => TicketInfo) private _tickets;
    mapping(uint256 => ListingInfo) private _listings;
    mapping(uint256 => uint256[]) private _eventTickets;
    mapping(uint256 => mapping(address => bool)) private _eventValidators;

    event OrganizerAdded(address indexed organizer);
    event ValidatorAdded(address indexed validator, uint256 indexed eventId);
    event EventCreated(uint256 indexed eventId, address indexed organizer, string eventName);
    event TicketMinted(uint256 indexed eventId, uint256 indexed tokenId, string seatInfo);
    event TicketPurchased(uint256 indexed eventId, uint256 indexed tokenId, address indexed buyer, uint256 price);
    event TicketListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event TicketListingCanceled(uint256 indexed tokenId, address indexed seller);
    event TicketResold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event TicketUsed(uint256 indexed tokenId, uint256 indexed eventId, address indexed validator);
    event EventStatusChanged(uint256 indexed eventId, bool active);

    constructor(address admin) ERC721("TRUST-TICKET", "TRUST") {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function addOrganizer(address organizer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (organizer == address(0)) revert InvalidAddress();
        _grantRole(ORGANIZER_ROLE, organizer);
        emit OrganizerAdded(organizer);
    }

    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        _grantRole(VALIDATOR_ROLE, validator);
        emit ValidatorAdded(validator, 0);
    }

    function addEventValidator(uint256 eventId, address validator) external {
        if (validator == address(0)) revert InvalidAddress();
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }

        _eventValidators[eventId][validator] = true;
        emit ValidatorAdded(validator, eventId);
    }

    function createEvent(
        string calldata eventName,
        uint256 eventTimestamp,
        uint256 ticketPrice,
        uint256 totalTicketCount,
        uint256 primarySaleStart,
        uint256 primarySaleEnd,
        bool resaleAllowed,
        uint256 maxResalePriceRate,
        uint256 resaleStart,
        uint256 resaleEnd
    ) external onlyRole(ORGANIZER_ROLE) returns (uint256 eventId) {
        if (ticketPrice == 0) revert InvalidPrice();
        if (totalTicketCount == 0) revert InvalidTicketSupply();
        if (primarySaleStart >= primarySaleEnd) revert InvalidSaleWindow();
        if (resaleAllowed) {
            if (resaleStart >= resaleEnd) revert InvalidSaleWindow();
            if (maxResalePriceRate < RESALE_RATE_DENOMINATOR) revert InvalidPrice();
        }

        eventId = _nextEventId++;
        _events[eventId] = EventInfo({
            eventId: eventId,
            organizer: msg.sender,
            eventName: eventName,
            eventTimestamp: eventTimestamp,
            ticketPrice: ticketPrice,
            totalTicketCount: totalTicketCount,
            remainingTicketCount: totalTicketCount,
            primarySaleStart: primarySaleStart,
            primarySaleEnd: primarySaleEnd,
            resaleAllowed: resaleAllowed,
            maxResalePriceRate: maxResalePriceRate,
            resaleStart: resaleStart,
            resaleEnd: resaleEnd,
            active: true
        });

        emit EventCreated(eventId, msg.sender, eventName);
    }

    function setEventStatus(uint256 eventId, bool active) external {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }
        eventInfo.active = active;
        emit EventStatusChanged(eventId, active);
    }

    function mintTicket(uint256 eventId, string calldata seatInfo) external returns (uint256 tokenId) {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer) revert NotEventOrganizer();
        if (_eventTickets[eventId].length >= eventInfo.totalTicketCount) revert InvalidTicketSupply();

        tokenId = _nextTokenId++;
        _tickets[tokenId] = TicketInfo({
            tokenId: tokenId,
            eventId: eventId,
            seatInfo: seatInfo,
            originalPrice: eventInfo.ticketPrice,
            used: false,
            listed: false
        });
        _eventTickets[eventId].push(tokenId);
        _mint(address(this), tokenId);

        emit TicketMinted(eventId, tokenId, seatInfo);
    }

    function purchaseTicket(uint256 tokenId) external payable nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);

        if (!eventInfo.active) revert EventInactive();
        if (block.timestamp < eventInfo.primarySaleStart || block.timestamp > eventInfo.primarySaleEnd) {
            revert PrimarySaleClosed();
        }
        if (msg.value != eventInfo.ticketPrice) revert InvalidPrice();
        if (!_checkPurchaseEligibility(msg.sender, ticket.eventId)) revert PurchaseNotEligible();
        if (ticket.used) revert TicketUsedError();
        if (ticket.listed) revert TicketListedError();
        if (ownerOf(tokenId) != address(this)) revert TicketUnavailable();
        if (eventInfo.remainingTicketCount == 0) revert TicketUnavailable();

        eventInfo.remainingTicketCount -= 1;
        _safeTransfer(address(this), msg.sender, tokenId, "");

        (bool paid, ) = eventInfo.organizer.call{value: msg.value}("");
        if (!paid) revert PaymentTransferFailed();

        emit TicketPurchased(ticket.eventId, tokenId, msg.sender, msg.value);
    }

    function listTicket(uint256 tokenId, uint256 resalePrice) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);

        if (ownerOf(tokenId) != msg.sender) revert NotTicketOwner();
        if (!eventInfo.active) revert EventInactive();
        if (ticket.used) revert TicketUsedError();
        if (ticket.listed) revert TicketListedError();
        if (!eventInfo.resaleAllowed) revert ResaleNotAllowed();
        if (block.timestamp < eventInfo.resaleStart || block.timestamp > eventInfo.resaleEnd) revert ResaleClosed();
        if (resalePrice == 0) revert InvalidPrice();

        uint256 maxPrice = (ticket.originalPrice * eventInfo.maxResalePriceRate) / RESALE_RATE_DENOMINATOR;
        if (resalePrice > maxPrice) revert PriceCapExceeded();

        ticket.listed = true;
        _listings[tokenId] = ListingInfo({tokenId: tokenId, seller: msg.sender, price: resalePrice, active: true});

        emit TicketListed(tokenId, msg.sender, resalePrice);
    }

    function cancelListing(uint256 tokenId) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        ListingInfo storage listing = _listings[tokenId];

        if (!ticket.listed || !listing.active) revert TicketNotListed();
        if (ownerOf(tokenId) != msg.sender) revert NotTicketOwner();

        address seller = listing.seller;
        ticket.listed = false;
        delete _listings[tokenId];

        emit TicketListingCanceled(tokenId, seller);
    }

    function purchaseResaleTicket(uint256 tokenId) external payable nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);
        ListingInfo memory listing = _listings[tokenId];

        if (!eventInfo.active) revert EventInactive();
        if (ticket.used) revert TicketUsedError();
        if (!ticket.listed || !listing.active) revert TicketNotListed();
        if (block.timestamp < eventInfo.resaleStart || block.timestamp > eventInfo.resaleEnd) revert ResaleClosed();
        if (msg.sender == listing.seller) revert SelfPurchase();
        if (msg.value != listing.price) revert InvalidPrice();
        if (!_checkPurchaseEligibility(msg.sender, ticket.eventId)) revert PurchaseNotEligible();
        if (ownerOf(tokenId) != listing.seller) revert TicketUnavailable();

        ticket.listed = false;
        delete _listings[tokenId];

        _marketplaceTransfer = true;
        _safeTransfer(listing.seller, msg.sender, tokenId, "");
        _marketplaceTransfer = false;

        (bool paid, ) = listing.seller.call{value: msg.value}("");
        if (!paid) revert PaymentTransferFailed();

        emit TicketResold(tokenId, listing.seller, msg.sender, msg.value);
    }

    function useTicket(uint256 tokenId) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        if (!_isValidatorForEvent(ticket.eventId, msg.sender)) revert NotValidator();
        if (ticket.used) revert TicketUsedError();
        if (ownerOf(tokenId) == address(this)) revert TicketUnavailable();

        if (ticket.listed) {
            address seller = _listings[tokenId].seller;
            ticket.listed = false;
            delete _listings[tokenId];
            emit TicketListingCanceled(tokenId, seller);
        }

        ticket.used = true;
        emit TicketUsed(tokenId, ticket.eventId, msg.sender);
    }

    function getEventInfo(uint256 eventId) external view returns (EventInfo memory) {
        return _requireEventView(eventId);
    }

    function getTicketInfo(uint256 tokenId) external view returns (TicketInfo memory) {
        return _requireTicketView(tokenId);
    }

    function getListingInfo(uint256 tokenId) external view returns (ListingInfo memory) {
        _requireTicketView(tokenId);
        return _listings[tokenId];
    }

    function getTicketsByEvent(uint256 eventId) external view returns (uint256[] memory) {
        _requireEventView(eventId);
        return _eventTickets[eventId];
    }

    function getTicketsByOwner(address owner) external view returns (uint256[] memory tokenIds) {
        if (owner == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf(owner);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    function isTicketValid(uint256 tokenId) external view returns (bool) {
        TicketInfo memory ticket = _requireTicketView(tokenId);
        EventInfo memory eventInfo = _requireEventView(ticket.eventId);
        return eventInfo.active && !ticket.used && ownerOf(tokenId) != address(this);
    }

    function isTicketListed(uint256 tokenId) external view returns (bool) {
        TicketInfo memory ticket = _requireTicketView(tokenId);
        return ticket.listed && _listings[tokenId].active;
    }

    function _checkPurchaseEligibility(address buyer, uint256 eventId) internal view virtual returns (bool) {
        buyer;
        eventId;
        return true;
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Enumerable) returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !_marketplaceTransfer) {
            TicketInfo memory ticket = _tickets[tokenId];
            if (ticket.used) revert TicketUsedError();
            if (ticket.listed) revert TicketListedError();
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _isValidatorForEvent(uint256 eventId, address validator) private view returns (bool) {
        return hasRole(VALIDATOR_ROLE, validator) || _eventValidators[eventId][validator];
    }

    function _requireEvent(uint256 eventId) private view returns (EventInfo storage eventInfo) {
        eventInfo = _events[eventId];
        if (eventInfo.eventId == 0) revert InvalidEvent();
    }

    function _requireTicket(uint256 tokenId) private view returns (TicketInfo storage ticket) {
        ticket = _tickets[tokenId];
        if (ticket.tokenId == 0) revert TicketUnavailable();
    }

    function _requireEventView(uint256 eventId) private view returns (EventInfo memory eventInfo) {
        eventInfo = _events[eventId];
        if (eventInfo.eventId == 0) revert InvalidEvent();
    }

    function _requireTicketView(uint256 tokenId) private view returns (TicketInfo memory ticket) {
        ticket = _tickets[tokenId];
        if (ticket.tokenId == 0) revert TicketUnavailable();
    }
}
