/**
 * Cytoscape.js Network Topology Viewer
 * Converts NeXt UI topology data to Cytoscape.js format
 */

// Register dagre layout
cytoscape.use(cytoscapeDagre);

// Global cytoscape instance
let cy = null;
let currentLayout = 'dagre-tb'; // Default to Vertical layout

// Color mapping for link states - NeXt UI style
const LINK_COLORS = {
    normal: '#aaaaaa',   // Light gray for normal links
    missing: '#FF0000',  // Red for missing (LLDP down)
    fail: '#FFED29',     // Yellow for unexpected
    dead: '#E40039',     // Dark red for dead
    new: '#148D09'       // Green for new (NeXt UI color)
};

// Node colors by icon type
const NODE_COLORS = {
    switch: '#5b9bd5',
    router: '#70ad47', 
    firewall: '#c00000',
    server: '#7030a0',
    unknown: '#666666'
};

// NeXt UI font icon unicode characters
const ICON_CHARS = {
    switch: '\ue618',
    switchbg: '\ue619',
    router: '\ue61c',
    routerbg: '\ue61d',
    firewall: '\ue640',
    server: '\ue612',
    unknown: '?'
};


/**
 * Get link color based on status
 */
function getLinkColor(link) {
    if (link.is_dead === 'yes') return LINK_COLORS.dead;
    if (link.is_new === 'yes') return LINK_COLORS.new;
    if (link.is_missing === 'yes') return LINK_COLORS.missing;
    if (link.is_missing === 'fail') return LINK_COLORS.fail;
    return LINK_COLORS.normal;
}

/**
 * Get link style (dashed for dead links)
 */
function getLinkStyle(link) {
    if (link.is_dead === 'yes') return 'dashed';
    return 'solid';
}

/**
 * Convert NeXt UI topology data to Cytoscape.js format
 */
function convertToCytoscapeFormat(topologyData) {
    const elements = [];
    
    // Convert nodes
    topologyData.nodes.forEach(node => {
        const iconType = node.icon || 'switch';
        const color = NODE_COLORS[iconType] || NODE_COLORS.switch;
        const iconChar = ICON_CHARS[iconType] || ICON_CHARS.switch;
        const bgChar = ICON_CHARS[iconType + 'bg'] || '';
        
        elements.push({
            data: {
                id: 'n' + node.id,
                label: node.name,
                level: node.layerSortPreference || 5,
                icon: iconType,
                iconChar: iconChar,
                iconBgChar: bgChar,
                color: color,
                // Store original data
                primaryIP: node.primaryIP || 'N/A',
                model: node.model || 'N/A',
                serial_number: node.serial_number || 'N/A',
                version: node.version || 'N/A',
                dcimDeviceLink: node.dcimDeviceLink || '#'
            }
        });
    });
    
    // Convert edges
    topologyData.links.forEach(link => {
        elements.push({
            data: {
                id: 'e' + link.id,
                source: 'n' + link.source,
                target: 'n' + link.target,
                srcIfName: link.srcIfName,
                tgtIfName: link.tgtIfName,
                srcDevice: link.srcDevice,
                tgtDevice: link.tgtDevice,
                color: getLinkColor(link),
                lineStyle: getLinkStyle(link),
                is_missing: link.is_missing,
                is_dead: link.is_dead,
                is_new: link.is_new
            }
        });
    });
    
    return elements;
}

/**
 * Get layout options
 */
/**
 * Calculate hierarchical positions based on level
 */
function calculateHierarchicalPositions(direction) {
    const levels = {};
    
    // Group nodes by level
    cy.nodes().forEach(node => {
        const level = node.data('level') || 5;
        if (!levels[level]) levels[level] = [];
        levels[level].push(node);
    });
    
    // Sort levels
    const sortedLevels = Object.keys(levels).map(Number).sort((a, b) => a - b);
    
    const positions = {};
    const containerWidth = cy.width();
    const containerHeight = cy.height();
    const padding = 25;
    
    if (direction === 'TB') {
        // Top to Bottom - levels are rows
        // Increase level spacing by 1.2x
        const levelHeight = (containerHeight - padding * 2) / Math.max(sortedLevels.length - 1, 1) * 1.2;
        
        sortedLevels.forEach((level, levelIndex) => {
            const nodes = levels[level];
            // Increase node spacing by 1.3x
            const nodeWidth = (containerWidth - padding * 2) / nodes.length * 1.3;
            
            // Sort nodes by name for consistent ordering
            nodes.sort((a, b) => a.data('label').localeCompare(b.data('label')));
            
            nodes.forEach((node, nodeIndex) => {
                positions[node.id()] = {
                    x: padding + nodeWidth * nodeIndex + nodeWidth / 2,
                    y: padding + levelHeight * levelIndex
                };
            });
        });
    } else {
        // Left to Right - levels are columns
        // Increase level spacing for horizontal (1.8x)
        const levelWidth = (containerWidth - padding * 2) / Math.max(sortedLevels.length - 1, 1) * 1.8;
        
        sortedLevels.forEach((level, levelIndex) => {
            const nodes = levels[level];
            // Increase node spacing for horizontal (1.8x)
            const nodeHeight = (containerHeight - padding * 2) / nodes.length * 1.8;
            
            // Sort nodes by name for consistent ordering
            nodes.sort((a, b) => a.data('label').localeCompare(b.data('label')));
            
            nodes.forEach((node, nodeIndex) => {
                positions[node.id()] = {
                    x: padding + levelWidth * levelIndex,
                    y: padding + nodeHeight * nodeIndex + nodeHeight / 2
                };
            });
        });
    }
    
    return positions;
}

function getLayoutOptions(layoutType) {
    switch (layoutType) {
        case 'dagre-lr':
            return {
                name: 'preset',
                positions: calculateHierarchicalPositions('LR'),
                fit: true,
                padding: 25,
                animate: true,
                animationDuration: 300
            };
        case 'dagre-tb':
            return {
                name: 'preset',
                positions: calculateHierarchicalPositions('TB'),
                fit: true,
                padding: 25,
                animate: true,
                animationDuration: 300
            };
        case 'cose':
        default:
            return {
                name: 'cose',
                idealEdgeLength: 100,
                nodeOverlap: 20,
                refresh: 20,
                fit: true,
                padding: 5,
                randomize: false,
                componentSpacing: 100,
                nodeRepulsion: 400000,
                edgeElasticity: 100,
                nestingFactor: 5,
                gravity: 80,
                numIter: 1000,
                initialTemp: 200,
                coolingFactor: 0.95,
                minTemp: 1.0,
                animate: 'end',
                animationDuration: 500
            };
    }
}

/**
 * Set layout
 */
function setLayout(layoutType) {
    if (!cy) return;
    
    currentLayout = layoutType;
    
    // Update button states
    document.querySelectorAll('.toolbar button').forEach(btn => {
        btn.classList.remove('active');
    });
    
    const btnMap = {
        'dagre-lr': 'btn-hlr',
        'dagre-tb': 'btn-hud',
        'cose': 'btn-force'
    };
    
    const activeBtn = document.getElementById(btnMap[layoutType]);
    if (activeBtn) activeBtn.classList.add('active');
    
    // For hierarchical layouts, calculate positions first
    let layoutOptions;
    if (layoutType === 'dagre-lr') {
        layoutOptions = {
            name: 'preset',
            positions: calculateHierarchicalPositions('LR'),
            fit: true,
            padding: 25,
            animate: true,
            animationDuration: 300
        };
    } else if (layoutType === 'dagre-tb') {
        layoutOptions = {
            name: 'preset',
            positions: calculateHierarchicalPositions('TB'),
            fit: true,
            padding: 25,
            animate: true,
            animationDuration: 300
        };
    } else {
        layoutOptions = getLayoutOptions(layoutType);
    }
    
    // Run layout
    const layout = cy.layout(layoutOptions);
    layout.run();
}

/**
 * Show tooltip using mouse position
 */
function showTooltip(event, content) {
    const tooltip = document.getElementById('tooltip');
    if (!tooltip) return;
    
    // Get mouse position from original event
    const e = event.originalEvent;
    if (!e) return;
    
    tooltip.innerHTML = content;
    tooltip.style.display = 'block';
    tooltip.style.left = (e.clientX + 15) + 'px';
    tooltip.style.top = (e.clientY + 15) + 'px';
}

/**
 * Hide tooltip
 */
function hideTooltip() {
    const tooltip = document.getElementById('tooltip');
    if (tooltip) tooltip.style.display = 'none';
}

/**
 * Search for a device and show results
 */
function searchDevice(query) {
    const resultsDiv = document.getElementById('searchResults');
    
    if (!query || query.length < 2) {
        resultsDiv.classList.remove('show');
        return;
    }
    
    const lowerQuery = query.toLowerCase();
    const matches = cy.nodes().filter(node => {
        const label = node.data('label') || '';
        return label.toLowerCase().includes(lowerQuery);
    });
    
    if (matches.length === 0) {
        resultsDiv.innerHTML = '<div class="search-result-item" style="color:#888;">No results</div>';
        resultsDiv.classList.add('show');
        return;
    }
    
    // Limit to 10 results
    const limitedMatches = matches.slice(0, 10);
    
    resultsDiv.innerHTML = limitedMatches.map(node => 
        `<div class="search-result-item" onclick="focusNode('${node.id()}')">${node.data('label')}</div>`
    ).join('');
    
    resultsDiv.classList.add('show');
}

/**
 * Focus on a specific node
 */
function focusNode(nodeId) {
    const node = cy.getElementById(nodeId);
    if (!node || node.length === 0) return;
    
    // Hide search results
    document.getElementById('searchResults').classList.remove('show');
    document.getElementById('searchInput').value = node.data('label');
    
    // Animate to the node
    cy.animate({
        center: { eles: node },
        zoom: 1.5
    }, {
        duration: 500
    });
    
    // Highlight the node temporarily
    const originalBorderWidth = node.style('border-width');
    const originalBorderColor = node.style('border-color');
    
    node.style({
        'border-width': 4,
        'border-color': '#76b900'
    });
    
    // Reset after 3 seconds
    setTimeout(() => {
        node.style({
            'border-width': originalBorderWidth,
            'border-color': originalBorderColor
        });
    }, 3000);
}

// Close search results when clicking outside
document.addEventListener('click', function(e) {
    const searchBox = document.querySelector('.search-box');
    if (searchBox && !searchBox.contains(e.target)) {
        document.getElementById('searchResults').classList.remove('show');
    }
});

// Visibility states
let showPorts = false;  // Ports hidden by default
let showHostnames = true;
let showProblemsOnly = false;

/**
 * Toggle port labels visibility
 */
function togglePorts(show) {
    if (!cy) return;
    showPorts = show;
    
    // Use batch for better performance
    cy.batch(function() {
        cy.edges().style('text-opacity', show ? 1 : 0);
    });
    
    console.log('Ports visibility:', show);
}

/**
 * Toggle hostname labels visibility
 */
function toggleHostnames(show) {
    if (!cy) return;
    showHostnames = show;
    
    // Use batch for better performance
    cy.batch(function() {
        cy.nodes().style('text-opacity', show ? 1 : 0);
    });
    
    console.log('Hostname visibility:', show);
}

/**
 * Toggle problems only filter - show only missing/unexpected links
 */
function toggleProblems(show) {
    if (!cy) return;
    showProblemsOnly = show;
    
    cy.batch(function() {
        if (show) {
            // Hide normal links and their connected nodes (if isolated)
            cy.edges().forEach(edge => {
                const isMissing = edge.data('is_missing') === 'yes';
                const isUnexpected = edge.data('is_missing') === 'fail';
                const isProblem = isMissing || isUnexpected;
                
                edge.style('display', isProblem ? 'element' : 'none');
            });
            
            // Hide nodes that have no visible edges
            cy.nodes().forEach(node => {
                const visibleEdges = node.connectedEdges().filter(e => e.style('display') !== 'none');
                node.style('display', visibleEdges.length > 0 ? 'element' : 'none');
            });
            
            // Update icon overlays
            updateIconOverlays();
        } else {
            // Show all
            cy.edges().style('display', 'element');
            cy.nodes().style('display', 'element');
            updateIconOverlays();
        }
    });
    
    console.log('Problems only:', show);
}

/**
 * Run LLDP check
 */
function runLLDPCheck() {
    const button = document.getElementById('runLLDPCheck');
    button.disabled = true;
    button.textContent = '⏳ Running...';
    
    fetch('/trigger-lldp', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
    })
    .then(response => response.json())
    .then(data => {
        button.textContent = '✓ Done! Refreshing...';
        setTimeout(() => location.reload(), 5000);
    })
    .catch(error => {
        button.textContent = '❌ Error';
        button.disabled = false;
    });
}

/**
 * Initialize Cytoscape
 */
function initCytoscape() {
    if (typeof topologyData === 'undefined') {
        document.getElementById('status').textContent = '❌ No topology data';
        return;
    }
    
    const elements = convertToCytoscapeFormat(topologyData);
    
    cy = cytoscape({
        container: document.getElementById('cy'),
        elements: elements,
        style: [
            // Node style - transparent, icon shown via HTML overlay
            {
                selector: 'node',
                style: {
                    // Hostname label
                    'label': 'data(label)',
                    'text-valign': 'bottom',
                    'text-halign': 'center',
                    'font-size': '10px',
                    'font-family': 'Arial, sans-serif',
                    'color': '#ccc',
                    'text-margin-y': 9,
                    'text-background-color': '#212121',
                    'text-background-opacity': 0.8,
                    'text-background-padding': '2px',
                    // Transparent - icon shown via overlay
                    'background-color': 'transparent',
                    'background-opacity': 0,
                    'width': 40,
                    'height': 40,
                    'shape': 'ellipse',
                    'border-width': 0
                }
            },
            // Highlighted node
            {
                selector: 'node:selected',
                style: {
                    'border-width': 4,
                    'border-color': '#fff'
                }
            },
            // Edge style - NeXt UI style
            {
                selector: 'edge',
                style: {
                    'width': 1,
                    'line-color': 'data(color)',
                    'line-style': 'data(lineStyle)',
                    'curve-style': 'bezier',
                    'opacity': 0.7,
                    'target-arrow-shape': 'none',
                    'source-label': 'data(srcIfName)',
                    'target-label': 'data(tgtIfName)',
                    'source-text-offset': 20,
                    'target-text-offset': 20,
                    'font-size': '8px',
                    'color': '#999',
                    'text-rotation': 'autorotate',
                    'text-background-opacity': 0.85,
                    'text-background-color': '#212121',
                    'text-background-padding': '2px'
                }
            },
            // Highlighted edge
            {
                selector: 'edge:selected',
                style: {
                    'width': 4
                }
            }
        ],
        layout: { name: 'preset' }, // Initial - will switch to vertical after
        wheelSensitivity: 0.3,
        minZoom: 0.1,
        maxZoom: 3
    });
    
    // Update status
    const nodeCount = topologyData.nodes.length;
    const linkCount = topologyData.links.length;
    document.getElementById('status').textContent = `✅ ${nodeCount} nodes, ${linkCount} links`;
    
    // Update legend counts
    let normalCount = 0, missingCount = 0, unexpectedCount = 0;
    topologyData.links.forEach(link => {
        if (link.is_missing === 'yes') missingCount++;
        else if (link.is_missing === 'fail') unexpectedCount++;
        else normalCount++;
    });
    
    document.getElementById('count-normal').textContent = normalCount > 0 ? `[${normalCount}]` : '';
    document.getElementById('count-missing').textContent = missingCount > 0 ? `[${missingCount}]` : '';
    document.getElementById('count-unexpected').textContent = unexpectedCount > 0 ? `[${unexpectedCount}]` : '';
    
    // Node hover - show tooltip
    cy.on('mouseover', 'node', function(event) {
        const node = event.target;
        const data = node.data();
        const content = `
            <h4>${data.label}</h4>
            <p><span class="label">IP:</span> ${data.primaryIP}</p>
            <p><span class="label">Model:</span> ${data.model}</p>
            <p><span class="label">S/N:</span> ${data.serial_number}</p>
            <p><span class="label">Version:</span> ${data.version}</p>
        `;
        showTooltip(event, content);
    });
    
    cy.on('mouseout', 'node', hideTooltip);
    
    // Edge hover - show tooltip
    cy.on('mouseover', 'edge', function(event) {
        const edge = event.target;
        const data = edge.data();
        
        let status = 'Normal';
        let statusColor = '#76b900';
        if (data.is_missing === 'yes') { status = 'Missing'; statusColor = '#FF0000'; }
        else if (data.is_missing === 'fail') { status = 'Unexpected'; statusColor = '#FFED29'; }
        else if (data.is_dead === 'yes') { status = 'Dead'; statusColor = '#E40039'; }
        else if (data.is_new === 'yes') { status = 'New'; statusColor = '#76b900'; }
        
        const content = `
            <h4 style="color:${statusColor}">Link</h4>
            <p><strong>${data.srcDevice}</strong> : ${data.srcIfName}</p>
            <p>↕</p>
            <p><strong>${data.tgtDevice}</strong> : ${data.tgtIfName}</p>
            <p><span class="label">Status:</span> <span style="color:${statusColor}">${status}</span></p>
        `;
        showTooltip(event, content);
    });
    
    cy.on('mouseout', 'edge', hideTooltip);
    
    // Node click - open device page
    cy.on('tap', 'node', function(event) {
        const node = event.target;
        const link = node.data('dcimDeviceLink');
        if (link && link !== '#') {
            window.open(link, '_blank');
        }
    });
    
    // Apply Vertical layout as default
    setLayout('dagre-tb');
    
    // Hide port labels by default
    togglePorts(false);
    
    // Create HTML overlays for font icons
    createIconOverlays();
    
    // Update overlays on viewport change
    cy.on('viewport', updateIconOverlays);
    cy.on('position', 'node', updateIconOverlays);
    
    console.log('✅ Cytoscape.js initialized');
    console.log(`   Nodes: ${nodeCount}, Links: ${linkCount}`);
}

// Store overlay elements
let iconOverlays = [];

/**
 * Create HTML overlay elements for font icons
 */
function createIconOverlays() {
    const container = document.getElementById('cy');
    
    // Remove existing overlays
    iconOverlays.forEach(el => el.remove());
    iconOverlays = [];
    
    // Create overlay for each node
    cy.nodes().forEach(node => {
        const overlay = document.createElement('div');
        overlay.className = 'node-icon-overlay';
        overlay.dataset.nodeId = node.id();
        
        // Background layer (dark color)
        const bgChar = node.data('iconBgChar');
        if (bgChar) {
            const bgSpan = document.createElement('span');
            bgSpan.className = 'icon-bg';
            bgSpan.textContent = bgChar;
            overlay.appendChild(bgSpan);
        }
        
        // Foreground layer (colored)
        const fgSpan = document.createElement('span');
        fgSpan.className = 'icon-fg';
        fgSpan.textContent = node.data('iconChar');
        fgSpan.style.color = node.data('color');
        overlay.appendChild(fgSpan);
        
        container.appendChild(overlay);
        iconOverlays.push(overlay);
    });
    
    updateIconOverlays();
}

/**
 * Update overlay positions
 */
function updateIconOverlays() {
    if (!cy) return;
    
    const container = document.getElementById('cy');
    const containerRect = container.getBoundingClientRect();
    
    iconOverlays.forEach(overlay => {
        const node = cy.getElementById(overlay.dataset.nodeId);
        if (!node || node.length === 0) return;
        
        // Get rendered position relative to container
        const renderedPos = node.renderedPosition();
        
        overlay.style.left = renderedPos.x + 'px';
        overlay.style.top = renderedPos.y + 'px';
        overlay.style.fontSize = (24 * cy.zoom()) + 'px';
        
        // Hide overlay if node is hidden or zoom is too low
        const nodeVisible = node.style('display') !== 'none';
        overlay.style.display = (nodeVisible && cy.zoom() > 0.2) ? 'block' : 'none';
    });
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', initCytoscape);
