        html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <h1></h1>
    <title>BGP Neighbor Analysis</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
        .bgp-excellent {{ color: #4caf50; font-weight: bold; }}
        .bgp-good {{ color: #8bc34a; font-weight: bold; }}
        .bgp-warning {{ color: #ff9800; font-weight: bold; }}
        .bgp-critical {{ color: #f44336; font-weight: bold; }}
        .bgp-unknown {{ color: gray; }}
        .bgp-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        .bgp-table th, .bgp-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        .bgp-table th {{ background-color: #f2f2f2; }}
        
        /* Sortable table styling */
        .sortable {{
            cursor: pointer;
            user-select: none;
            position: relative;
            padding-right: 20px;
        }
        
        .sortable:hover {{
            background-color: #f5f5f5;
        }
        
        .sort-arrow {{
            font-size: 10px;
            color: #999;
            margin-left: 5px;
            opacity: 0.5;
        }
        
        .sortable.asc .sort-arrow::before {{
            content: '▲';
            color: #b57614;
            opacity: 1;
        }
        
        .sortable.desc .sort-arrow::before {{
            content: '▼';
            color: #b57614;
            opacity: 1;
        }
        
        .sortable.asc .sort-arrow,
        .sortable.desc .sort-arrow {{
            opacity: 1;
