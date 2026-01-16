async function getFileList() {
    try {
        console.log('Fetching directory listing...');
        const response = await fetch('../monitor-results/');
        const html = await response.text();
        console.log('Directory listing response:', html);
        const parser = new DOMParser();
        const doc = parser.parseFromString(html, 'text/html');
        const links = Array.from(doc.querySelectorAll('a'));
        const files = links
            .map(link => link.getAttribute('href'))
            .filter(href => href.endsWith('.html'));
        console.log('Found files:', files);
        return files;
    } catch (error) {
        console.error('Error fetching directory listing:', error);
        return [];
    }
}

async function performSearch() {
    let query = document.getElementById('searchInput').value.trim().toLowerCase();
    const resultContainer = document.getElementById('results');
    resultContainer.innerHTML = 'Loading...';
    if (/^([0-9a-f]{2}[:-]?){5}[0-9a-f]{2}$/i.test(query)) {
        query = normalizeMacAddress(query);
    }
    console.log('Search query:', query);
    const fileList = await getFileList();
    if (fileList.length === 0) {
        resultContainer.innerHTML = 'No files found in the directory or failed to fetch.';
        return;
    }
    let results = '';
    let filesSearched = 0;
    for (const file of fileList) {
        try {
            console.log(`Fetching content of ${file}...`);
            const response = await fetch(`monitor-results/${file}`);
            const text = await response.text();
            const lines = text.split('\n');
            const matchingLines = lines.filter(line => {
                const lowerLine = line.toLowerCase();
                return (
                    lowerLine.includes(query) &&
                    !lowerLine.includes('vxlan') &&
                    !lowerLine.includes('extern_learn')
                );
            });
            if (matchingLines.length > 0) {
                const fileName = file.replace('.html', '');
                results += `<h3><span style="color:green;">${fileName}</span></h3>`;
                matchingLines.forEach(line => {
                    results += `<pre>${highlightMatch(line, query)}</pre>`;
                });
            }
        } catch (error) {
            console.error(`Error fetching ${file}:`, error);
        }
        filesSearched++;
        resultContainer.innerHTML = `Searched ${filesSearched} of ${fileList.length} devices...`;
    }
    resultContainer.innerHTML = results || 'No results found.';
}

function normalizeMacAddress(mac) {
    return mac.replace(/[^a-f0-9]/ig, '').match(/.{1,2}/g).join(':');
}

function highlightMatch(text, query) {
    const regex = new RegExp(`(${escapeRegExp(query)})`, 'gi');
    return text.replace(regex, '<mark>$1</mark>');
}

function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function highlightMatch(text, query) {
    const regex = new RegExp(`(${escapeRegExp(query)})`, 'gi');
    return text.replace(regex, '<mark>$1</mark>');
}

function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
